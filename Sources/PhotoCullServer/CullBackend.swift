import Foundation

/// One preview image, either as a local file or as bytes.
public struct PreviewAsset: Sendable {
    /// Local file the server reads the JPEG from (Mac host).
    public var fileURL: URL?
    /// In-memory JPEG bytes (hosts without a local file).
    public var data: Data?
    /// Opaque cache token: the same etag means the same bytes. Quoting and
    /// `If-None-Match` matching are handled by the server.
    public var etag: String

    public init(fileURL: URL, etag: String) {
        self.fileURL = fileURL
        self.data = nil
        self.etag = etag
    }

    public init(data: Data, etag: String) {
        self.fileURL = nil
        self.data = data
        self.etag = etag
    }
}

/// Backend failures that map onto the contract's status codes.
public enum CullBackendError: Error, Sendable, Equatable {
    /// 400 — the request was well formed HTTP but cannot be satisfied as sent.
    case badRequest(String)
    /// 404 — unknown session or stem.
    case notFound(String)
    /// 409 — the session is locked (for example Finalize is running); retry later.
    case locked(String)
    /// 500 — the backend failed.
    case failure(String)
}

/// Everything the HTTP layer needs from a culling host.
///
/// Path parameters (`date`, `stem`) are passed through verbatim: the backend
/// validates them and answers `CullBackendError.notFound`, so the server never
/// builds a file path from request input.
public protocol CullBackend: Sendable {
    /// Display name returned by `GET /api/health`.
    var hostName: String { get }

    /// Newest first.
    func listSessions() async throws -> [SessionSummary]

    func sessionDetail(date: String) async throws -> SessionDetail

    func preview(date: String, stem: String) async throws -> PreviewAsset

    /// Applies already validated and clock-clamped changes with the sidecar
    /// merge rules, then returns the full session body.
    func applyChanges(date: String, changes: [SessionChange]) async throws -> SessionDetail
}
