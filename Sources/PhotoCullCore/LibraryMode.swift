import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// LibraryMode.swift — the data-safety gate, decided once at process start,
// before any config is read or AppState exists.
//
// REAL is reachable only from the installed app bundle: the executable must
// live inside an app bundle whose *canonical* (symlink-resolved) bundle path is
// /Applications/PhotoCull.app or ~/Applications/PhotoCull.app, and the bundle
// identifier must be local.photocull.swift. Everything else — `swift run`,
// .build/debug/PhotoCull, .build/release/PhotoCull, dist/PhotoCull.app, an
// app running from a mounted DMG, any other location — is DEV and uses the
// throwaway library under ~/Library/Caches/PhotoCull-Dev, never the real
// ~/Pictures/PhotoCull library or ~/.config/photocull config.
//
// Fixture mode (StartupConfiguration's disposable-fixture flow) takes
// precedence over both and is decided before this gate is consulted.

public enum LibraryMode: Equatable, Sendable {
    case real, dev, fixture

    /// The one process-wide mode. Set once at startup (PhotoCullMain), after
    /// fixture resolution. The safe default is DEV: any entry point that never
    /// ran the detection — test harnesses, check binaries, bare executables —
    /// can only ever reach the throwaway dev library.
    public static var current: LibraryMode = .dev

    /// Bundle identifier of the real, installed app.
    static let realBundleIdentifier = "local.photocull.swift"

    /// `~/Library/Caches/PhotoCull-Dev` — the DEV-mode library root.
    public static var devRoot: String {
        NSHomeDirectory() + "/Library/Caches/PhotoCull-Dev"
    }

    /// Mode for a given bundle identity + bundle path (`*.app` directory the
    /// executable lives in). Symlinks are resolved on both sides; only an
    /// exact canonical match against the installed locations yields REAL.
    public static func detect(bundleIdentifier: String?, bundlePath: String?) -> LibraryMode {
        guard bundleIdentifier == realBundleIdentifier,
              let bundlePath, !bundlePath.isEmpty,
              let resolved = canonical(bundlePath) else { return .dev }
        return realBundlePaths().contains(resolved) ? .real : .dev
    }

    /// Canonical (realpath) spellings of the two installed-bundle locations.
    static func realBundlePaths() -> [String] {
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PhotoCull.app").path
        return ["/Applications/PhotoCull.app", userApps].compactMap(canonical)
    }

    /// Whether `path` (absolute or `~`-relative, existing or not) is contained
    /// in the DEV root once symlinks are resolved. Symlink escapes out of the
    /// dev root fail this test. Used to reject dev configs or Settings saves
    /// that would point at real (or any outside) folders.
    public static func devContains(_ path: String) -> Bool {
        let root = canonical(devRoot) ?? devRoot
        var candidate = PCConfig.expandHome(path)
        var resolved = canonical(candidate)
        // realpath only resolves existing paths; walk up to the deepest
        // existing ancestor and judge containment from there.
        while resolved == nil {
            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate else { return false }
            candidate = parent
            resolved = canonical(candidate)
        }
        guard let base = resolved else { return false }
        return base == root || base.hasPrefix(root + "/")
    }

    /// Traps unless the dev root and its config folder are real directories
    /// (not symlinks) and the config file, if present, is a regular file, and
    /// the dev root does not resolve into the real library or config. A
    /// symlink planted there could otherwise route dev reads/writes — or the
    /// regeneration of a bad dev config — into real data. Dev builds only.
    public static func requireSafeDevRoot() {
        let fm = FileManager.default
        for dir in [devRoot, devRoot + "/config"] {
            if !fm.fileExists(atPath: dir) { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            var st = stat()
            precondition(lstat(dir, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR,
                         "PhotoCull dev root is not a real directory: \(dir)")
        }
        var st = stat()
        if lstat(devRoot + "/config/config.toml", &st) == 0 {
            precondition(st.st_mode & S_IFMT == S_IFREG, "PhotoCull dev config is not a regular file")
        }
        let root = canonical(devRoot) ?? devRoot
        for real in ["Pictures/PhotoCull", ".config/photocull"] {
            if let r = canonical(NSHomeDirectory() + "/" + real) {
                precondition(root != r && !root.hasPrefix(r + "/") && !r.hasPrefix(root + "/"),
                             "PhotoCull dev root overlaps real data: \(root)")
            }
        }
    }

    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
