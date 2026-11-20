import Foundation

// SessionStore.swift — the only sidecar write path outside Finalize.
// Read → merge → write under the session folder's cooperative lock, so the Mac
// app, the embedded HTTP API and (later) a server never clobber each other.
// The lock is the same `flock` Finalize holds for its whole run (see
// FinalizeSafety.swift). Writer/writer collisions last about a millisecond
// (both sides lock, merge, write), so the short retry below absorbs them;
// Finalize keeps the lock for its whole run, so contention with it still ends
// in `SessionLockedError` after the retry window.

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
    /// How long `update` keeps retrying the session folder lock before
    /// reporting `SessionLockedError`. Long enough for the other writer's
    /// merge to finish, short enough that a running Finalize (which owns the
    /// lock for minutes) is reported promptly.
    public static let lockRetryWindow: TimeInterval = 0.25
    static let lockRetryInterval: TimeInterval = 0.005

    /// Merge `incoming` (the writer's session) into `folder`'s on-disk sidecar
    /// and return exactly what was written. Per (stem, field) the larger stamp
    /// wins and an equal stamp keeps the on-disk value; `incoming`'s
    /// `last_index` is written as the writer's own cursor.
    @discardableResult
    /// `retryFor` bounds the lock wait; main-thread callers pass a short one.
    public static func merge(_ incoming: Session, folder: URL,
                             retryFor window: TimeInterval = lockRetryWindow) throws -> Session {
        try update(folder, retryFor: window) { disk in disk.merged(with: incoming) }
    }

    /// Apply remote changes to the on-disk sidecar with the same rule and
    /// return the written session. Replaying a queue is idempotent.
    @discardableResult
    public static func apply(_ changes: [SessionChange], folder: URL) throws -> Session {
        try update(folder, retryFor: lockRetryWindow) { disk in
            for change in changes { disk.apply(change) }
            return disk
        }
    }

    /// Read → merge → atomic write while holding the session folder lock.
    /// The sidecar is read through the pinned directory descriptor (never a
    /// swapped symlink), and a strictly unreadable one throws instead of
    /// being replaced.
    private static func update(_ folder: URL, retryFor window: TimeInterval,
                               _ merge: (Session) throws -> Session) throws -> Session {
        let directory = try lock(folder, retryFor: window)
        defer { directory.releaseLock() }
        let disk = try FinalizeSidecar.capture(directory).session()
        let merged = try merge(disk)
        // The lock pins the original inode; refuse if the path now names another folder.
        try directory.verifyVisible()
        try merged.save(folder: directory.url)
        return merged
    }

    /// Take the session folder lock, retrying briefly while another writer
    /// holds it. Anything else (not a directory, I/O failure) is thrown as is.
    private static func lock(_ folder: URL, retryFor window: TimeInterval) throws -> FinalizeDirectory {
        let deadline = Date().addingTimeInterval(window)
        while true {
            do {
                return try FinalizeDirectory(folder, lock: true)
            } catch let error as FinalizeSafetyError where error.lockContention {
                guard Date() < deadline else { throw SessionLockedError(path: folder.path) }
                Thread.sleep(forTimeInterval: lockRetryInterval)
            }
        }
    }
}

/// Posted after the embedded HTTP API applied changes to a session, so the Mac
/// UI can refresh a sidebar row it did not itself change. Posted on the writing
/// thread; observers hop to the main actor.
public enum RemoteSessionNotice {
    public static let applied = Notification.Name("PhotoCull.remoteSessionChangesApplied")
    /// `userInfo` key carrying the session `date`.
    public static let dateKey = "date"
}
