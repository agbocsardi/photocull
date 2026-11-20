import Foundation
import CoreGraphics
import Darwin

// PreviewStore.swift — the remote-culling preview cache (docs/REMOTE-CULL.md §4).
//
// Previews are JPEG, long edge <= 2048, EXIF orientation applied, no crop/tilt/
// rotation (the client applies `rotation`), sRGB. They live *outside* the inbox
// at `<parent of inbox>/.photocull-previews/<date>/<STEM>.jpg`:
//   * the inbox must stay photos + sidecar (Finalize's cleanup refuses anything
//     else), and Library.loadSessions treats every inbox subfolder as a session.
// The path derives from the already mode-gated cfg, so dev builds cache inside
// the dev library. This type never reads config itself.
//
// Each preview has a tiny `<STEM>.jpg.src` sidecar with the source's size and
// modification time; a preview whose recorded source differs is regenerated.
// JPEGs are written to a dot-prefixed temp file in the same folder and renamed
// into place, so a concurrent reader never sees a partial file.

public struct Preview: Sendable, Equatable {
    public var url: URL
    /// Stable token derived from the source's size + mtime and the preview
    /// format version. Changes whenever the preview is regenerated. URL-safe
    /// (no quoting needed in `?v=<etag>`).
    public var etag: String
    public init(url: URL, etag: String) {
        self.url = url; self.etag = etag
    }
}

public enum PreviewError: Error, Equatable, CustomStringConvertible {
    /// `date`/`stem` (or the configured inbox path) is not usable as a plain path component.
    case invalidComponent(String)
    /// The source JPG is missing, unreadable, or not a regular file.
    case sourceUnreadable(String)
    /// ImageIO could not decode the source.
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .invalidComponent(let detail): return "Preview: invalid path component — \(detail)"
        case .sourceUnreadable(let path): return "Preview: cannot read source \(path)"
        case .decodeFailed(let path): return "Preview: cannot decode \(path)"
        }
    }
}

public enum PreviewStore {
    /// Bumped when the rendering (size, quality, pipeline) changes so old
    /// previews are regenerated instead of being served with a fresh ETag.
    public static let formatVersion = 1
    public static let maxPixel = 2048
    public static let quality = 0.8

    /// `<parent of inbox>/.photocull-previews`.
    static let cacheFolderName = ".photocull-previews"

    // MARK: - Public API

    /// URL and ETag of the preview for `pair.jpg` in session `date`, generating
    /// (or regenerating) it when missing or stale. Errors are thrown for bad
    /// `date`/`stem` and unreadable sources; the cache folder is created here.
    public static func preview(cfg: PCConfig, date: String, pair: FilePair) throws -> Preview {
        try validate(date, name: "date")
        try validate(pair.stem, name: "stem")
        let folder = try directory(cfg: cfg, date: date)
        let previewURL = folder.appendingPathComponent(pair.stem + ".jpg")
        let stampURL = folder.appendingPathComponent(pair.stem + ".jpg.src")
        let stamp = try sourceStamp(pair.jpg)

        // Serialize per preview path: concurrent callers for the same stem wait
        // instead of writing the same file twice, then see the fresh result
        // below. Distinct stems mostly generate in parallel (striped locks).
        let lock = lock(forPath: previewURL.path)
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        if fm.fileExists(atPath: previewURL.path),
           let recorded = try? String(contentsOf: stampURL, encoding: .utf8),
           recorded == stamp.text {
            return Preview(url: previewURL, etag: stamp.etag)
        }

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try generate(source: pair.jpg, to: previewURL, stamp: stamp, stampURL: stampURL)
        return Preview(url: previewURL, etag: stamp.etag)
    }

    /// ETag the preview for `pair` carries right now, without generating it.
    /// Used to build the `?v=<etag>` preview URL in a session listing; matches
    /// what `preview(cfg:date:pair:)` returns for the same source.
    public static func etag(for pair: FilePair) throws -> String {
        try sourceStamp(pair.jpg).etag
    }

    /// Generate every missing/stale preview for `date` in the background: low
    /// QoS, bounded concurrency, skipping the work already up to date. Cancel
    /// the returned task to stop it between photos; errors are swallowed (a
    /// single unreadable source must not abort the warm-up).
    @discardableResult
    public static func warm(cfg: PCConfig, date: String, pairs: [FilePair],
                            concurrency: Int = 3) -> Task<Void, Never> {
        let width = min(max(concurrency, 1), 4)
        return Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < pairs.count, next < width {
                    let pair = pairs[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        _ = try? preview(cfg: cfg, date: date, pair: pair)
                    }
                }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll() }
                    guard !Task.isCancelled, next < pairs.count else { continue }
                    let pair = pairs[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        _ = try? preview(cfg: cfg, date: date, pair: pair)
                    }
                }
            }
        }
    }

    /// Drop one date's cached previews (session finalized or removed). No-op
    /// when nothing was cached. Nothing outside the preview cache is touched.
    /// Cancel any `warm` task for `date` first, or it can recreate previews.
    public static func remove(cfg: PCConfig, date: String) throws {
        try validate(date, name: "date")
        let folder = try directory(cfg: cfg, date: date)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Paths and validation

    /// `<parent of inbox>/.photocull-previews/<date>` — never inside the inbox.
    static func directory(cfg: PCConfig, date: String) throws -> URL {
        let inbox = PCConfig.expandHome(cfg.paths.inbox)
        guard inbox.hasPrefix("/") else {
            throw PreviewError.invalidComponent("inbox path is not absolute: \(cfg.paths.inbox)")
        }
        return URL(fileURLWithPath: inbox)
            .deletingLastPathComponent()
            .appendingPathComponent(cacheFolderName)
            .appendingPathComponent(date)
    }

    /// Reject anything that is not a single ordinary path component, so a
    /// hostile `date` or `stem` can never climb out of the cache folder.
    static func validate(_ value: String, name: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("/"), !value.contains("\\"), !value.utf8.contains(0) else {
            throw PreviewError.invalidComponent("\(name) \"\(value)\" is not a plain path component")
        }
    }

    // MARK: - Source stamp / ETag

    struct SourceStamp: Equatable {
        var size: UInt64
        var mtimeNs: UInt64

        /// Sidecar contents: version, size, mtime.
        var text: String { "\(PreviewStore.formatVersion) \(size) \(mtimeNs)\n" }

        var etag: String {
            String(format: "v%d-%llx-%llx", PreviewStore.formatVersion, size, mtimeNs)
        }
    }

    /// Size + modification time of the source JPG (nanosecond resolution).
    static func sourceStamp(_ url: URL) throws -> SourceStamp {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw PreviewError.sourceUnreadable(url.path)
        }
        let seconds = UInt64(max(st.st_mtimespec.tv_sec, 0))
        let nanos = UInt64(max(st.st_mtimespec.tv_nsec, 0))
        // Wrapping arithmetic: only stability matters, and a nonsense timestamp
        // must not trap.
        return SourceStamp(size: UInt64(max(st.st_size, 0)),
                           mtimeNs: seconds &* 1_000_000_000 &+ nanos)
    }

    // MARK: - Rendering

    /// Decode a 2048px orientation-corrected thumbnail, write it as sRGB JPEG to
    /// a temp file, rename it into place, then record the source stamp.
    static func generate(source: URL, to dst: URL, stamp: SourceStamp, stampURL: URL) throws {
        guard let image = ImagePipeline.load(url: source, maxPixel: maxPixel) else {
            throw PreviewError.decodeFailed(source.path)
        }
        let temp = dst.deletingLastPathComponent()
            .appendingPathComponent(".\(dst.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try ImagePipeline.writeJPEG(sRGB(image), to: temp, quality: quality)
            if FileManager.default.fileExists(atPath: dst.path) {
                _ = try FileManager.default.replaceItemAt(dst, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: dst)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        // Written after the JPEG: a crash here only costs one regeneration.
        try Data(stamp.text.utf8).write(to: stampURL, options: .atomic)
    }

    /// Re-render into sRGB when the source carries another profile (P3 camera
    /// JPEGs, greyscale, Display P3 screenshots).
    static func sRGB(_ image: CGImage) -> CGImage {
        if let space = image.colorSpace, space.name == CGColorSpace.sRGB { return image }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    // MARK: - Per-path locks

    /// Fixed stripe of locks: same-path callers always share one, and the
    /// set never grows with the library.
    private static let stripes = (0..<16).map { _ in NSLock() }

    private static func lock(forPath path: String) -> NSLock {
        stripes[Int(UInt(bitPattern: path.hashValue) % UInt(stripes.count))]
    }
}
