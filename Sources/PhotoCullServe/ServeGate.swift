import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PhotoCullCore
import PhotoCullHost

// ServeGate.swift — which library this host may serve, and the bearer token it
// needs (docs/REMOTE-CULL.md §6).
//
// The Mac app's LibraryMode gate still rules: this executable's own location
// never decides the mode. DEV is the default and always serves the throwaway
// dev root. REAL is an explicit opt-in — `--real` plus a data root the owner has
// marked with `.photocull-serve-root` — and is still refused if the root is,
// contains, or sits inside the app's real data. The server never creates the
// root, its marker, or its inbox.
//
// All of this is deliberately in the executable target: the app's own gate does
// not need to know that a second kind of host exists.

/// What the host serves.
struct Library {
    var mode: LibraryMode
    var cfg: PCConfig
    /// Root that gets logged and that REAL derives its folders from.
    var root: String
}

/// A startup refusal after a valid-looking command line: message, exit 1.
struct StartupError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum ServeGate {
    /// The owner creates this once in a REAL data root; the server only checks it.
    static let markerName = ".photocull-serve-root"

    // MARK: - Library

    static func resolve(_ options: ServeOptions) throws -> Library {
        guard options.real else { return devLibrary() }
        guard let root = options.dataRoot else {
            throw StartupError("--real requires --data-root PATH")
        }
        return try realLibrary(root)
    }

    /// DEV: the same throwaway library a dev build of the app uses.
    private static func devLibrary() -> Library {
        LibraryMode.current = .dev
        LibraryMode.requireSafeDevRoot()
        return Library(mode: .dev, cfg: PCConfig.devDefaultConfig(), root: LibraryMode.devRoot)
    }

    /// REAL: an explicit, owner-marked data root, refused if it could reach the
    /// app's real library or config.
    private static func realLibrary(_ raw: String) throws -> Library {
        guard raw.hasPrefix("/") else {
            throw StartupError("--data-root must be an absolute path: \(raw)")
        }
        var info = stat()
        guard lstat(raw, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw StartupError("--data-root must be an existing real directory, not a symlink: \(raw)")
        }
        guard let root = canonical(raw) else {
            throw StartupError("cannot resolve --data-root: \(raw)")
        }
        guard root != "/" else {
            throw StartupError("--data-root must not be the filesystem root")
        }
        for protected in protectedRoots() {
            if root == protected {
                throw StartupError("--data-root \(root) is protected PhotoCull data; refusing")
            }
            if root.hasPrefix(protected + "/") {
                throw StartupError("--data-root \(root) is inside protected data \(protected); refusing")
            }
            if protected.hasPrefix(root + "/") {
                throw StartupError("--data-root \(root) contains protected data \(protected); refusing")
            }
        }

        let marker = root + "/" + markerName
        var markerInfo = stat()
        guard lstat(marker, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG else {
            throw StartupError("--data-root \(root) has no \(markerName) marker; create that file "
                + "once to mark the folder as a PhotoCull data root")
        }

        // The mode is decided before anything downstream can read it.
        LibraryMode.current = .real
        let defaults = PCConfig.defaultConfig()
        let cfg = PCConfig(
            paths: PathsConfig(inbox: root + "/inbox",
                               archive: root + "/archive",
                               dump: root + "/dump"),
            files: defaults.files,
            finalize: defaults.finalize)
        return Library(mode: .real, cfg: cfg, root: root)
    }

    /// Folders a REAL data root may never equal, contain, or live inside: the
    /// dev root by its canonical spelling (or the plain one when it does not
    /// exist yet) and the app's real library and config.
    private static func protectedRoots() -> [String] {
        let home = NSHomeDirectory()
        let paths = [
            LibraryMode.devRoot,
            home + "/Pictures/PhotoCull",
            home + "/.config/photocull",
        ]
        return paths.map { canonical($0) ?? URL(fileURLWithPath: $0).standardized.path }
    }

    // MARK: - Token

    /// The bearer token: a private regular file, trimmed, at least 32 characters.
    /// Never logged; every message here names the file only.
    static func readToken(at path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw StartupError("--token-file does not exist: \(path)")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw StartupError("--token-file must be a regular file, not a symlink or special file: \(path)")
        }
        guard info.st_mode & 0o077 == 0 else {
            throw StartupError("--token-file must not be readable or writable by group or others "
                + "(chmod 600): \(path)")
        }

        // O_NOFOLLOW closes the gap between the lstat checks and the read.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw StartupError("cannot open --token-file: \(path)")
        }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw StartupError("--token-file changed while opening: \(path)")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw StartupError("cannot read --token-file: \(path)")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 64_384 else {
                throw StartupError("--token-file is too large: \(path)")
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw StartupError("--token-file is not UTF-8: \(path)")
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32 else {
            throw StartupError("--token-file holds \(token.count) characters; a token needs at "
                + "least 32: \(path)")
        }
        return token
    }

    // MARK: - PWA

    /// `--pwa` when given, otherwise the app's own resolution: a REAL host with
    /// no bundled PWA serves the API only.
    static func pwaRoot(_ options: ServeOptions) throws -> URL? {
        guard let path = options.pwa else {
            return PWAStaticRoot.resolve(mode: LibraryMode.current)
        }
        // Static assets may be reached through a symlinked folder; the contract
        // only asks that --pwa be a directory.
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ServeOptions.UsageError.message("--pwa must be an existing directory: \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Paths

    private static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
