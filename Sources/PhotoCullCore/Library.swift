import Foundation

// Library.swift — app-facing rollups over the inbox.

public struct SessionRow: Identifiable, Sendable, Equatable {
    public var date: String
    public var total: Int
    public var keep: Int
    public var reject: Int
    public var undecided: Int
    public var status: FolderStatus
    public var cropped: Int
    public var id: String { date }
    public init(date: String, total: Int, keep: Int, reject: Int,
                undecided: Int, status: FolderStatus, cropped: Int) {
        self.date = date; self.total = total; self.keep = keep
        self.reject = reject; self.undecided = undecided
        self.status = status; self.cropped = cropped
    }
    /// 0...1 completion fraction.
    public var progress: Double { total == 0 ? 0 : Double(keep + reject) / Double(total) }
}

public enum Library {
    /// All inbox date folders, newest first (descending date string compare).
    /// Skips unreadable folders; returns [] when the inbox is missing.
    public static func loadSessions(cfg: PCConfig) -> [SessionRow] {
        let inbox = inboxFolder(cfg: cfg, date: "")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        var rows: [SessionRow] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let date = entry.lastPathComponent

            guard let row = row(cfg: cfg, folder: entry, date: date) else { continue }
            rows.append(row)
        }

        rows.sort { $0.date > $1.date }
        return rows
    }

    /// One session row re-derived from disk, or nil when `date` is not a
    /// session folder. Cheap enough for the sidebar to refresh a single row
    /// after another writer (the embedded API) changed that session.
    public static func row(cfg: PCConfig, date: String) -> SessionRow? {
        let folder = inboxFolder(cfg: cfg, date: date)
        let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDir else { return nil }
        return row(cfg: cfg, folder: folder, date: date)
    }

    private static func row(cfg: PCConfig, folder: URL, date: String) -> SessionRow? {
        guard let pairs = try? FilePairs.pairs(folder: folder,
                                               jpgExts: cfg.jpgExtSet,
                                               rawExts: cfg.rawExtSet) else { return nil }

        // Corrupt session file behaves like a fresh one (Go ignores the error).
        let session = (try? Session.load(folder: folder)) ?? Session.fresh()
        let stems = FilePairs.stems(pairs)
        let counts = session.statusCounts(stems: stems)
        return SessionRow(date: date,
                          total: pairs.count,
                          keep: counts.keep,
                          reject: counts.reject,
                          undecided: counts.undecided,
                          status: session.folderStatus(stems: stems),
                          cropped: session.crops.count)
    }

    /// Pairs for one date folder.
    public static func pairs(cfg: PCConfig, date: String) throws -> [FilePair] {
        try FilePairs.pairs(folder: inboxFolder(cfg: cfg, date: date),
                            jpgExts: cfg.jpgExtSet, rawExts: cfg.rawExtSet)
    }

    /// Absolute inbox folder URL for a date (empty date → the inbox itself).
    public static func inboxFolder(cfg: PCConfig, date: String) -> URL {
        let inbox = URL(fileURLWithPath: PCConfig.expandHome(cfg.paths.inbox))
        return date.isEmpty ? inbox : inbox.appendingPathComponent(date)
    }
}
