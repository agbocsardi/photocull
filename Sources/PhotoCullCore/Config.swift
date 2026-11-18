import Foundation
import Darwin

// Config.swift — reads/writes ~/.config/photocull/config.toml
// Byte-compatible with the Go implementation's config format.

public struct PathsConfig: Codable, Sendable, Equatable {
    public var inbox: String
    public var archive: String
    public var dump: String
    public init(inbox: String, archive: String, dump: String) {
        self.inbox = inbox; self.archive = archive; self.dump = dump
    }
}

public struct FilesConfig: Codable, Sendable, Equatable {
    public var rawExtensions: [String]
    public var jpgExtensions: [String]
    public init(rawExtensions: [String], jpgExtensions: [String]) {
        self.rawExtensions = rawExtensions; self.jpgExtensions = jpgExtensions
    }
}

/// Finalize defaults stored in the `[finalize]` config section.
public struct FinalizeConfig: Codable, Sendable, Equatable {
    /// `crop_export = "crop"`.
    public static let cropExportCrop = "crop"
    /// `crop_export = "original"`.
    public static let cropExportOriginal = "original"

    /// Whether keeper JPG copies are written to the exports folder on finalize.
    public var exportJPGs: Bool
    /// `"crop"` or `"original"` — see `cropExportMode`.
    public var cropExport: String

    public init(exportJPGs: Bool = true, cropExport: String = FinalizeConfig.cropExportCrop) {
        self.exportJPGs = exportJPGs; self.cropExport = cropExport
    }

    /// The `[finalize]` value mapped onto the finalize engine's export mode.
    public var cropExportMode: CropExportMode { cropExport == FinalizeConfig.cropExportOriginal ? .original : .applyCrop }
}

public struct PCConfig: Codable, Sendable, Equatable {
    public var paths: PathsConfig
    public var files: FilesConfig
    public var finalize: FinalizeConfig
    public init(paths: PathsConfig, files: FilesConfig,
                finalize: FinalizeConfig = FinalizeConfig()) {
        self.paths = paths; self.files = files; self.finalize = finalize
    }

    /// Defaults. Paths and keys match the Go app; the RAW extension list is a
    /// deliberate divergence — Go shipped only RAF/RW2, the port covers the
    /// common camera brands so a stock config pairs most libraries.
    public static func defaultConfig() -> PCConfig {
        PCConfig(
            paths: PathsConfig(inbox: "~/Pictures/PhotoCull/inbox",
                               archive: "~/Pictures/PhotoCull/archive",
                               dump: "~/Downloads"),
            files: FilesConfig(rawExtensions: ["RAF", "RW2", "CR2", "CR3", "NEF", "ARW", "DNG", "ORF", "PEF"],
                               jpgExtensions: ["JPG", "JPEG"]))
    }

    /// Absolute path of the config file. REAL/fixture mode (installed app):
    /// `~/.config/photocull/config.toml`. DEV mode: the throwaway config under
    /// `~/Library/Caches/PhotoCull-Dev/config/config.toml` — development runs
    /// can never read or write the real config.
    public static var configPath: String {
        if LibraryMode.current != .real {
            LibraryMode.requireSafeDevRoot()
            return LibraryMode.devRoot + "/config/config.toml"
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config")
            .appendingPathComponent("photocull")
            .appendingPathComponent("config.toml").path
    }

    /// Load config, creating the default file when missing. `~/` is expanded.
    /// In DEV mode this never touches the real config: it loads (and creates
    /// if missing) the throwaway config under the dev root, and regenerates it
    /// if it ever points outside that root.
    public static func load() -> PCConfig {
        switch LibraryMode.current {
        case .real: return load(from: URL(fileURLWithPath: configPath))
        case .dev: return loadDev()
        case .fixture: preconditionFailure("Fixture mode must use its explicit validated config")
        }
    }

    /// Default DEV config: every path pinned inside the dev root.
    public static func devDefaultConfig() -> PCConfig {
        let root = URL(fileURLWithPath: LibraryMode.devRoot)
        return PCConfig(paths: PathsConfig(inbox: root.appendingPathComponent("inbox").path,
                                           archive: root.appendingPathComponent("archive").path,
                                           dump: root.appendingPathComponent("export").path),
                        files: FilesConfig(rawExtensions: ["RAF", "RW2"], jpgExtensions: ["JPG", "JPEG"]))
    }

    /// DEV loader. The dev config is generated with dev-root paths when
    /// missing, and a config whose paths point outside the dev root (e.g. at
    /// the real library) is refused and regenerated — dev must never be
    /// configurable to point at real folders.
    static func loadDev() -> PCConfig {
        LibraryMode.requireSafeDevRoot()
        let url = URL(fileURLWithPath: LibraryMode.devRoot + "/config/config.toml")
        var cfg = devDefaultConfig()
        if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
            applyTOML(TOMLParser.parse(text), into: &cfg)
            cfg.paths.inbox = expandHome(cfg.paths.inbox)
            cfg.paths.archive = expandHome(cfg.paths.archive)
            cfg.paths.dump = expandHome(cfg.paths.dump)
            let contained = [cfg.paths.inbox, cfg.paths.archive, cfg.paths.dump]
                .allSatisfy { LibraryMode.devContains($0) }
            if !contained {
                cfg = devDefaultConfig()
                try? writeDefaultConfig(cfg, to: url)
            }
        } else {
            try? writeDefaultConfig(cfg, to: url)
        }
        return cfg
    }

    /// Load config from an explicit file path (testable variant of `load()`).
    /// Missing file → write defaults there, then use defaults.
    /// Unreadable file or parse failure → fall back to defaults. Never fatal.
    public static func load(from url: URL) -> PCConfig {
        var cfg = PCConfig.defaultConfig()

        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            applyTOML(TOMLParser.parse(text), into: &cfg)
        } else {
            // Missing or unreadable: best-effort write of the default file.
            try? writeDefaultConfig(cfg, to: url)
        }

        cfg.paths.inbox = expandHome(cfg.paths.inbox)
        cfg.paths.archive = expandHome(cfg.paths.archive)
        cfg.paths.dump = expandHome(cfg.paths.dump)
        return cfg
    }

    /// Strict, read-only loader for generated disposable fixtures, never normal config/defaults.
    public static func loadFixture(from path: String) throws -> PCConfig {
        func reject(_ message: String) -> Error {
            NSError(domain: "PhotoCull.Fixture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        func inspect(_ path: String, directory: Bool) throws -> stat {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_uid == getuid(),
                  st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                  st.st_mode & 0o444 != 0,
                  directory || st.st_nlink == 1 else { throw reject("Not a readable owned non-symlink fixture item: \(path)") }
            return st
        }
        let components = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/private/tmp/"), !path.utf8.contains(0), components.count == 5,
              path == "/" + components.joined(separator: "/"), !components.contains("."), !components.contains("..") else {
            throw reject("Fixture config must have an absolute canonical generated-root/config/config.toml spelling")
        }
        let url = URL(fileURLWithPath: path), root = url.deletingLastPathComponent().deletingLastPathComponent()
        guard url.lastPathComponent == "config.toml", url.deletingLastPathComponent().lastPathComponent == "config",
              root.lastPathComponent.hasPrefix("photocull-manual-fixture-") || root.lastPathComponent.hasPrefix("photocull-manual-launch-") else {
            throw reject("Expected generated fixture root/config/config.toml")
        }
        // Inspect each ancestor BEFORE realpath/open so a bad link cannot lead into user data.
        for ancestor in ["/private", "/private/tmp"] {
            var st = stat()
            guard lstat(ancestor, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw reject("Fixture ancestor is not a real directory") }
        }
        let rootInfo = try inspect(root.path, directory: true)
        guard rootInfo.st_mode & 0o077 == 0 else { throw reject("Fixture root must be private to its owner") }
        _ = try inspect(url.deletingLastPathComponent().path, directory: true)
        let before = try inspect(path, directory: false)
        guard let resolved = realpath(path, nil) else { throw reject("Cannot resolve fixture config") }
        defer { free(resolved) }
        guard path == String(cString: resolved) else { throw reject("Fixture config path is not canonical") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw reject("Cannot read fixture config") }
        defer { close(fd) }
        var pinned = stat()
        guard fstat(fd, &pinned) == 0, pinned.st_dev == before.st_dev, pinned.st_ino == before.st_ino else {
            throw reject("Fixture config replaced while opening")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw reject("Cannot read fixture config") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 16_384 else { throw reject("Fixture config is too large") }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw reject("Fixture config is not UTF-8") }
        let parsed = TOMLParser.parse(text)
        guard case .string(let inbox)? = parsed["paths"]?["inbox"],
              case .string(let archive)? = parsed["paths"]?["archive"],
              case .string(let dump)? = parsed["paths"]?["dump"],
              case .array(let raw)? = parsed["files"]?["raw_extensions"],
              case .array(let jpg)? = parsed["files"]?["jpg_extensions"] else {
            throw reject("Incomplete fixture config")
        }
        let cfg = PCConfig(paths: PathsConfig(inbox: inbox, archive: archive, dump: dump),
                           files: FilesConfig(rawExtensions: raw, jpgExtensions: jpg))
        // ponytail: generated-only TOML ceiling; ordinary config parsing remains permissive/unchanged.
        guard text == cfg.toTOML(), raw == ["RAF", "RW2"], jpg == ["JPG", "JPEG"],
              inbox == root.appendingPathComponent("inbox").path,
              archive == root.appendingPathComponent("archive").path,
              dump == root.appendingPathComponent("export").path else {
            throw reject("Fixture config must exactly match the generated TOML and contained inbox/archive/export paths")
        }
        for path in [inbox, archive, dump] {
            _ = try inspect(path, directory: true)
            var enumerationError: Error?
            guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                errorHandler: { _, error in enumerationError = error; return false }) else { throw reject("Cannot enumerate fixture data") }
            for case let item as URL in entries {
                var st = stat()
                guard lstat(item.path, &st) == 0, item.path.hasPrefix(path + "/"),
                      st.st_mode & S_IFMT == S_IFDIR || st.st_mode & S_IFMT == S_IFREG else {
                    throw reject("Symlink/special item in fixture: \(item.path)")
                }
                _ = try inspect(item.path, directory: st.st_mode & S_IFMT == S_IFDIR)
            }
            if let error = enumerationError { throw error }
        }
        var after = stat()
        let visible = try inspect(path, directory: false)
        guard fstat(fd, &after) == 0, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              visible.st_dev == before.st_dev, visible.st_ino == before.st_ino else { throw reject("Fixture config changed during validation") }
        return cfg
    }

    /// Overlay parsed TOML values onto `cfg` (only known keys, only matching shapes).
    static func applyTOML(_ parsed: [String: [String: TOMLValue]], into cfg: inout PCConfig) {
        if let section = parsed["paths"] {
            if case .string(let v)? = section["inbox"] { cfg.paths.inbox = v }
            if case .string(let v)? = section["archive"] { cfg.paths.archive = v }
            if case .string(let v)? = section["dump"] { cfg.paths.dump = v }
        }
        if let section = parsed["files"] {
            if case .array(let v)? = section["raw_extensions"], !v.isEmpty { cfg.files.rawExtensions = v }
            if case .array(let v)? = section["jpg_extensions"], !v.isEmpty { cfg.files.jpgExtensions = v }
        }
        if let section = parsed["finalize"] {
            if case .bool(let v)? = section["export_jpgs"] { cfg.finalize.exportJPGs = v }
            if case .string(let v)? = section["crop_export"],
               v == FinalizeConfig.cropExportCrop || v == FinalizeConfig.cropExportOriginal {
                cfg.finalize.cropExport = v
            }
        }
    }

    /// Write the default config file, creating parent directories as needed.
    static func writeDefaultConfig(_ cfg: PCConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try cfg.toTOML().data(using: .utf8)?.write(to: url)
    }

    /// Uppercased JPG extension set.
    public var jpgExtSet: Set<String> { Set(files.jpgExtensions.map { $0.uppercased() }) }
    /// Uppercased RAW extension set.
    public var rawExtSet: Set<String> { Set(files.rawExtensions.map { $0.uppercased() }) }

    /// Expand a leading `~/` to the user's home directory.
    public static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + "/" + path.dropFirst(2)
    }

    /// Abbreviate a path under the user's home directory back to `~/…` form,
    /// the counterpart of `expandHome`. Paths elsewhere are returned unchanged.
    public static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.count > home.count, path.hasPrefix(home + "/") else { return path }
        return "~/" + path.dropFirst(home.count + 1)
    }

    /// Save to the config file, writing paths back in `~/…` form when they are
    /// under the home directory. Atomic; creates the parent directory.
    public func save(to url: URL = URL(fileURLWithPath: configPath)) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(toTOML().utf8).write(to: url, options: .atomic)
    }

    /// Human-readable problems with this configuration, for the settings
    /// window to show inline before Apply. Pure: the filesystem is inspected
    /// read-only and nothing is created.
    /// Path used only to compare folders: symlinks in the deepest existing
    /// ancestor resolved via realpath, lowercased because APFS is
    /// case-insensitive by default (a false "same folder" beats a missed one).
    static func comparablePath(_ path: String) -> String {
        var head = (path as NSString).standardizingPath, tail: [String] = []
        while true {
            if let resolved = realpath(head, nil) {
                head = String(cString: resolved); free(resolved); break
            }
            if head == "/" { break }
            tail.insert((head as NSString).lastPathComponent, at: 0)
            head = (head as NSString).deletingLastPathComponent
        }
        return ([head] + tail).joined(separator: "/").replacingOccurrences(of: "//", with: "/").lowercased()
    }

    public func validate() -> [String] {
        var problems: [String] = []

        // Per-path check. Returns the canonicalized path, or nil when unusable.
        func check(_ name: String, _ raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                problems.append("No folder path for \(name).")
                return nil
            }
            let expanded = Self.expandHome(trimmed)
            guard expanded.hasPrefix("/") else {
                problems.append("\(name) requires an absolute path: \(Self.abbreviateHome(trimmed)).")
                return nil
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                problems.append("The \(name) path exists but isn’t a folder: \(Self.abbreviateHome(expanded)).")
            }
            return Self.comparablePath(expanded)
        }

        if LibraryMode.current == .dev {
            for (name, path) in [("Inbox", paths.inbox), ("Archive", paths.archive), ("Exports", paths.dump)]
            where !path.isEmpty && !LibraryMode.devContains(path) {
                problems.append("Development builds only use folders inside \(Self.abbreviateHome(LibraryMode.devRoot)): \(name) is outside it.")
            }
        }

        let existing: [(String, String)] = [
            ("Inbox", check("Inbox", paths.inbox)),
            ("Archive", check("Archive", paths.archive)),
            ("Exports", check("Exports", paths.dump))
        ].compactMap { name, path in path.map { (name, $0) } }
        for i in 0..<existing.count {
            for j in (i + 1)..<existing.count {
                let a = existing[i], b = existing[j]
                if a.1 == b.1 {
                    problems.append("\(a.0) and \(b.0) use the same folder.")
                } else if a.1.hasPrefix(b.1 + "/") {
                    problems.append("The \(a.0) folder is inside the \(b.0) folder.")
                } else if b.1.hasPrefix(a.1 + "/") {
                    problems.append("The \(b.0) folder is inside the \(a.0) folder.")
                }
            }
        }

        let raws = files.rawExtensions.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        let jpgs = files.jpgExtensions.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        if raws.filter({ !$0.isEmpty }).isEmpty { problems.append("Enter at least one RAW extension.") }
        if jpgs.filter({ !$0.isEmpty }).isEmpty { problems.append("Enter at least one JPG extension.") }
        let overlap = Set(raws.filter { !$0.isEmpty }).intersection(jpgs.filter { !$0.isEmpty })
        if !overlap.isEmpty {
            problems.append("\(overlap.sorted().joined(separator: ", ")): " +
                            "listed under both RAW and JPG.")
        }
        return problems
    }

    /// Serialize back to TOML in the same shape Go's toml.Marshal produces:
    /// `[section]` header, 2-space indented `key = value` lines, blank line
    /// between sections, trailing newline. Strings are escaped for `\` and `"`
    /// (the parser unescapes both), and home paths are written back as `~/…`.
    public func toTOML() -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func array(_ a: [String]) -> String { "[" + a.map(quoted).joined(separator: ", ") + "]" }
        var out = ""
        out += "[paths]\n"
        out += "  inbox = \(quoted(Self.abbreviateHome(paths.inbox)))\n"
        out += "  archive = \(quoted(Self.abbreviateHome(paths.archive)))\n"
        out += "  dump = \(quoted(Self.abbreviateHome(paths.dump)))\n"
        out += "\n[files]\n"
        out += "  raw_extensions = \(array(files.rawExtensions))\n"
        out += "  jpg_extensions = \(array(files.jpgExtensions))\n"
        out += "\n[finalize]\n"
        out += "  export_jpgs = \(finalize.exportJPGs)\n"
        out += "  crop_export = \(quoted(finalize.cropExport))\n"
        return out
    }
}

public enum TOMLValue: Sendable, Equatable {
    case string(String)
    case array([String])
    case bool(Bool)
}

/// Minimal TOML reader for the shapes used by photocull configs:
/// `[section]` headers, `key = "string"`, `key = ["a", "b"]`, `#` comments.
public enum TOMLParser {
    /// Parse `text` into `[section: [key: value]]`. Keys outside any section
    /// are stored under the `""` section.
    public static func parse(_ text: String) -> [String: [String: TOMLValue]] {
        var result: [String: [String: TOMLValue]] = ["": [:]]
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[") {
                guard let end = line.firstIndex(of: "]") else { continue }
                let name = String(line[line.index(after: line.startIndex)..<end])
                    .trimmingCharacters(in: .whitespaces)
                section = name
                if result[section] == nil { result[section] = [:] }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = stripTrailingComment(value)

            if value.hasPrefix("\"") {
                if let str = parseQuoted(value) {
                    result[section]?[key] = .string(str)
                }
            } else if value.hasPrefix("[") {
                let items = splitArrayItems(value).compactMap { parseQuoted($0) }
                result[section]?[key] = .array(items)
            } else if value == "true" || value == "false" {
                result[section]?[key] = .bool(value == "true")
            }
        }
        return result
    }

    /// Cut a trailing `# comment` that sits outside of any quoted string.
    static func stripTrailingComment(_ value: String) -> String {
        var inQuote = false
        var escaped = false
        for (i, ch) in value.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == "#" && !inQuote {
                return String(value.prefix(i)).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    /// Given a value starting with `"`, return the unescaped string content.
    static func parseQuoted(_ value: String) -> String? {
        guard let first = value.first, first == "\"" else { return nil }
        var out = ""
        var escaped = false
        var idx = value.index(after: value.startIndex)
        while idx < value.endIndex {
            let ch = value[idx]
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return out
            } else {
                out.append(ch)
            }
            idx = value.index(after: idx)
        }
        return nil // unterminated string
    }

    /// Split `[ "a", "b" ]` contents into raw item strings.
    static func splitArrayItems(_ value: String) -> [String] {
        var inner = value
        if inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix("]") { inner.removeLast() }
        return inner.components(separatedBy: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
