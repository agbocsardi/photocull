import Foundation
import Darwin
import CoreGraphics
import ImageIO

/// Tiny test harness (XCTest is unavailable in a CommandLineTools-only toolchain).

public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    public func snapshot() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

nonisolated(unsafe) var pcFailures: [String] = []
nonisolated(unsafe) var pcChecks = 0

public func check(_ cond: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    pcChecks += 1
    if cond {
        print("  ok   \(msg)")
    } else {
        let where_ = "\(file):\(line)"
        pcFailures.append("\(msg)  [\(where_)]")
        print("  FAIL \(msg)  [\(where_)]")
    }
}

public func checkEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String,
                                     file: String = #fileID, line: Int = #line) {
    check(a == b, "\(msg) (got \(a), want \(b))", file: file, line: line)
}

public func checkClose(_ a: Double, _ b: Double, _ tol: Double = 0.001, _ msg: String,
                       file: String = #fileID, line: Int = #line) {
    check(abs(a - b) <= tol, "\(msg) (got \(a), want \(b)±\(tol))", file: file, line: line)
}

public func suite(_ name: String, _ body: () throws -> Void) {
    print("\n== \(name) ==")
    do { try body() } catch { pcFailures.append("\(name) threw: \(error)"); print("  THREW \(error)") }
}

/// Create a unique temp directory; callers own its cleanup.
public func makeTempDir(_ tag: String) throws -> URL {
    let base = ProcessInfo.processInfo.environment["PC_TEST_ROOT"] ?? NSTemporaryDirectory()
    let url = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("pc-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

public func touch(_ url: URL, bytes: Int = 8) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

/// Kernel-canonical path spelling (realpath of the deepest existing ancestor,
/// plus any not-yet-existing suffix) — matches how Core's Finalize canonicalises
/// configured roots before reporting paths, so expectations can compare against
/// the spelling the product actually returns on symlinked roots like /var.
public func canonicalPath(_ url: URL) -> String {
    var ancestor = url.path, suffix = ""
    while ancestor != "/" {
        var st = stat()
        if lstat(ancestor, &st) == 0 { break }
        guard errno == ENOENT else { return url.path }
        suffix = "/" + (ancestor as NSString).lastPathComponent + suffix
        ancestor = (ancestor as NSString).deletingLastPathComponent
    }
    guard let resolved = realpath(ancestor, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved) + suffix
}

/// A generated stand-in for a camera JPEG: 2048×1365 with Fujifilm X-S20 EXIF
/// (capture date, ISO, shutter, aperture). Written once per run, so the suite needs
/// no real photos and runs the same on any machine. `PC_FIXTURES` can still point
/// at a folder of real files with the same name.
public func fixtureURL(_ name: String) -> URL? {
    if let base = ProcessInfo.processInfo.environment["PC_FIXTURES"] {
        let u = URL(fileURLWithPath: base).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return syntheticFixture
}

private let syntheticFixture: URL? = {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("photocull-fixture-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("20240503-DSCF2771.jpeg")
    let w = 2048, h = 1365
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    for i in 0..<16 {   // coarse colour blocks so crops and thumbnails differ
        ctx.setFillColor(CGColor(red: CGFloat(i % 4) / 3, green: CGFloat(i / 4) / 3, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: (i % 4) * w / 4, y: (i / 4) * h / 4, width: w / 4, height: h / 4))
    }
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    let props: [CFString: Any] = [
        kCGImageDestinationLossyCompressionQuality: 0.8,
        kCGImagePropertyOrientation: 1,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM",
                                         kCGImagePropertyTIFFModel: "X-S20"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:03 14:22:31",
                                         kCGImagePropertyExifISOSpeedRatings: [640],
                                         kCGImagePropertyExifExposureTime: 1.0 / 250,
                                         kCGImagePropertyExifFNumber: 2.8],
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? url : nil
}()
