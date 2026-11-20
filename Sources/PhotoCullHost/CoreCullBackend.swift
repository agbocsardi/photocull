import Foundation
import PhotoCullCore
import PhotoCullServer

// CoreCullBackend.swift — the Mac host side of HTTP API v1 (docs/REMOTE-CULL.md).
//
// Every answer comes from the app's own mode-gated `PCConfig`, so the embedded
// server serves exactly the library the Mac app shows (DEV builds included) and
// a request can never point it at another folder: `date` and `stem` are only
// ever compared against real, enumerated names.
//
// All of this is blocking file I/O, so every method is deliberately
// nonisolated: the server awaits it from its own tasks, never on the main actor.

public struct CoreCullBackend: CullBackend {
    public let cfg: PCConfig
    public let hostName: String

    public init(cfg: PCConfig, hostName: String) {
        self.cfg = cfg
        self.hostName = hostName
    }

    // MARK: - CullBackend

    public func listSessions() async throws -> [SessionSummary] {
        Library.loadSessions(cfg: cfg).map(Self.summary)
    }

    public func sessionDetail(date: String) async throws -> SessionDetail {
        let folder = try sessionFolder(date: date)
        let pairs = try pairs(in: folder, date: date)
        let session = try loadSession(folder, date: date)
        return detail(date: date, session: session, pairs: pairs, rev: Self.revision(folder))
    }

    public func preview(date: String, stem: String) async throws -> PreviewAsset {
        let pair = try validatedPair(date: date, stem: stem)
        do {
            let preview = try PreviewStore.preview(cfg: cfg, date: date, pair: pair)
            return PreviewAsset(fileURL: preview.url, etag: preview.etag)
        } catch let error as PreviewError {
            switch error {
            case .invalidComponent: throw CullBackendError.notFound(error.description)
            case .sourceUnreadable, .decodeFailed: throw CullBackendError.failure(error.description)
            }
        } catch {
            throw CullBackendError.failure("preview failed: \(error.localizedDescription)")
        }
    }

    public func applyChanges(date: String,
                             changes: [PhotoCullServer.SessionChange]) async throws -> SessionDetail {
        let folder = try sessionFolder(date: date)
        let pairs = try pairs(in: folder, date: date)
        let known = Set(pairs.map(\.stem))

        // Validate the whole batch before writing anything: a queue that names
        // an unknown photo is a client bug, not a partial apply.
        var incoming: [PhotoCullCore.SessionChange] = []
        incoming.reserveCapacity(changes.count)
        for change in changes {
            let stem = change.stem.uppercased()
            guard known.contains(stem) else {
                throw CullBackendError.notFound("unknown photo \(change.stem) in session \(date)")
            }
            switch change.value {
            case .decision(let value):
                incoming.append(.init(stem: stem, field: .decision,
                                      value: .decision(Self.decision(value)), at: change.at))
            case .rotation(let turns):
                incoming.append(.init(stem: stem, field: .rotation,
                                      value: .rotation(turns), at: change.at))
            }
        }

        // Nothing to do: do not rewrite the sidecar (and churn `rev`) for a no-op.
        if incoming.isEmpty {
            let session = try loadSession(folder, date: date)
            return detail(date: date, session: session, pairs: pairs, rev: Self.revision(folder))
        }

        let session: Session
        do {
            session = try SessionStore.apply(incoming, folder: folder)
        } catch is SessionLockedError {
            throw CullBackendError.locked("session \(date) is locked by another writer; retry")
        } catch let error as Session.SidecarError {
            throw CullBackendError.failure(error.localizedDescription)
        } catch {
            throw CullBackendError.failure("could not save session \(date): \(error.localizedDescription)")
        }

        // Lets the Mac's sidebar catch up on a session it does not have open;
        // the open session is merged by its own ~1 s sidecar poll.
        NotificationCenter.default.post(name: RemoteSessionNotice.applied, object: nil,
                                        userInfo: [RemoteSessionNotice.dateKey: date])
        return detail(date: date, session: session, pairs: pairs, rev: Self.revision(folder))
    }

    // MARK: - Validation

    /// The inbox's own child folder named `date`, or 404. This is the same set
    /// `GET /api/sessions` lists (it skips only folders it cannot read), and
    /// the URL comes from the directory entry, never from the request string.
    private func sessionFolder(date: String) throws -> URL {
        let inbox = URL(fileURLWithPath: PCConfig.expandHome(cfg.paths.inbox))
        let children = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children where child.lastPathComponent == date {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { return child }
        }
        throw CullBackendError.notFound("unknown session \(date)")
    }

    private func pairs(in folder: URL, date: String) throws -> [FilePair] {
        do {
            return try FilePairs.pairs(folder: folder, jpgExts: cfg.jpgExtSet, rawExts: cfg.rawExtSet)
        } catch {
            throw CullBackendError.failure("cannot read session \(date): \(error.localizedDescription)")
        }
    }

    /// `stem` must be one of the session's actual (uppercased) stems.
    private func validatedPair(date: String, stem: String) throws -> FilePair {
        let folder = try sessionFolder(date: date)
        let all = try pairs(in: folder, date: date)
        let wanted = stem.uppercased()
        guard let pair = all.first(where: { $0.stem == wanted }) else {
            throw CullBackendError.notFound("unknown photo \(stem) in session \(date)")
        }
        return pair
    }

    private func loadSession(_ folder: URL, date: String) throws -> Session {
        do {
            // Strict: a corrupt or unsafe sidecar is reported rather than
            // shown (and later written back) as an empty session.
            return try Session.load(folder: folder, strict: true)
        } catch let error as Session.SidecarError {
            throw CullBackendError.failure(error.localizedDescription)
        } catch {
            throw CullBackendError.failure("cannot read session \(date): \(error.localizedDescription)")
        }
    }

    // MARK: - Wire mapping

    private func detail(date: String, session: Session, pairs: [FilePair],
                        rev: String) -> SessionDetail {
        let photos = pairs.map { pair -> SessionPhoto in
            let crop = session.crop(for: pair.stem).map {
                PhotoCullServer.CropRect(x: $0.x, y: $0.y, w: $0.w, h: $0.h)
            }
            return SessionPhoto(stem: pair.stem,
                                hasRaw: pair.hasRAW,
                                decision: Self.decision(session.get(pair.stem)),
                                rotation: session.quarterTurns(for: pair.stem),
                                tilt: session.tilt(for: pair.stem),
                                crop: crop,
                                preview: previewPath(date: date, stem: pair.stem,
                                                     etag: previewETag(pair)))
        }
        return SessionDetail(date: date, rev: rev, lastIndex: session.lastIndex, photos: photos)
    }

    /// `/api/sessions/<date>/photos/<stem>/preview?v=<etag>`, each path
    /// component percent-escaped (stems may carry spaces or punctuation).
    private func previewPath(date: String, stem: String, etag: String) -> String {
        "/api/sessions/\(Self.pathComponent(date))/photos/\(Self.pathComponent(stem))/preview?v=\(etag)"
    }

    /// Source-derived, so it matches what the preview route will serve.
    /// A source that cannot be stat'ed falls back to a format-only tag; the
    /// preview request then reports the real failure.
    private func previewETag(_ pair: FilePair) -> String {
        (try? PreviewStore.etag(for: pair)) ?? "v\(PreviewStore.formatVersion)"
    }

    private static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func decision(_ value: Decision) -> DecisionValue {
        switch value {
        case .keep: return .keep
        case .reject: return .reject
        case .undecided: return .undecided
        }
    }

    private static func decision(_ value: DecisionValue) -> Decision {
        switch value {
        case .keep: return .keep
        case .reject: return .reject
        case .undecided: return .undecided
        }
    }

    private static func summary(_ row: SessionRow) -> SessionSummary {
        let status: SessionStatus
        switch row.status {
        case .empty: status = .empty
        case .unstarted: status = .unstarted
        case .inProgress: status = .inProgress
        case .complete: status = .complete
        }
        return SessionSummary(date: row.date, total: row.total, keep: row.keep,
                              reject: row.reject, undecided: row.undecided, status: status)
    }

    /// Opaque `rev`: a hash of the sidecar's bytes, so it changes whenever the
    /// sidecar does and a replayed write (identical bytes) keeps the same value.
    /// Sidecars are small; reading one is cheaper than a client polling detail.
    private static func revision(_ folder: URL) -> String {
        let url = folder.appendingPathComponent(Session.fileName)
        guard let data = try? Data(contentsOf: url) else { return "0" }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325   // FNV-1a
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
