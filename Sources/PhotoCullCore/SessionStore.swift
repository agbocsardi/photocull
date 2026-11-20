import Foundation

// SessionStore.swift — the only sidecar write path outside Finalize.
// Read → merge → write under the session folder's cooperative lock, so the Mac
// app, the embedded HTTP API and (later) a server never clobber each other.
// The lock is the same `flock` Finalize holds for its whole run (see
// FinalizeSafety.swift), so a writer fails fast instead of racing a Finalize.

/// The session folder lock is held elsewhere (Finalize, or another writer in
/// the middle of its own merge). The HTTP layer maps this to 409: retry later.
public struct SessionLockedError: Error, LocalizedError, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
    public var errorDescription: String? {
        "Session is locked by another writer or by Finalize: \(path)"
    }
}

public enum SessionStore {
    /// Merge `incoming` (the writer's session) into `folder`'s on-disk sidecar
    /// and return exactly what was written. Per (stem, field) the larger stamp
    /// wins and an equal stamp keeps the on-disk value; `incoming`'s
    /// `last_index` is written as the writer's own cursor.
    @discardableResult
    public static func merge(_ incoming: Session, folder: URL) throws -> Session {
        try update(folder) { disk in disk.merged(with: incoming) }
    }

    /// Apply remote changes to the on-disk sidecar with the same rule and
    /// return the written session. Replaying a queue is idempotent.
    @discardableResult
    public static func apply(_ changes: [SessionChange], folder: URL) throws -> Session {
        try update(folder) { disk in
            for change in changes { disk.apply(change) }
            return disk
        }
    }

    /// Read → merge → atomic write while holding the session folder lock.
    /// The sidecar is read through the pinned directory descriptor (never a
    /// swapped symlink), and a strictly unreadable one throws instead of
    /// being replaced.
    private static func update(_ folder: URL, _ merge: (Session) throws -> Session) throws -> Session {
        let directory: FinalizeDirectory
        do { directory = try FinalizeDirectory(folder, lock: true) }
        catch let error as FinalizeSafetyError where error.lockContention {
            throw SessionLockedError(path: folder.path)
        }
        defer { directory.releaseLock() }
        let disk = try FinalizeSidecar.capture(directory).session()
        let merged = try merge(disk)
        // The lock pins the original inode; refuse if the path now names another folder.
        try directory.verifyVisible()
        try merged.save(folder: directory.url)
        return merged
    }
}
