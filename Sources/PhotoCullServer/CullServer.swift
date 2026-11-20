import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// Failures of the server itself (not of the culling host).
public enum CullServerError: Error, Sendable, Equatable {
    case alreadyRunning
    case emptyToken
    /// `start()` returned before the listener came up, for example because it was stopped immediately.
    case stoppedBeforeStart
}

/// Embedded HTTP API v1 (docs/REMOTE-CULL.md §3).
///
/// Binds one local host and port, serves the PWA from `staticRoot` without auth and
/// every `/api` route behind a bearer token, and forwards all data questions to a
/// `CullBackend`. Start and stop are async so a SwiftUI app can drive them from a `Task`.
public actor CullServer {
    /// Loopback only: remote access is `tailscale serve`'s job.
    public static let defaultHost = "127.0.0.1"
    /// Port the app uses for the phone bridge.
    public static let defaultPort = 8723
    /// Contract: at most ~1 MB per changes request.
    public static let maxBodyBytes = 1_048_576
    /// Contract: at most ~1000 changes per request.
    public static let maxChanges = 1000
    /// Contract: a client's `at` may not run further ahead of the server clock.
    public static let maxClockSkewMillis: Int64 = 60_000

    private struct Running {
        let group: ServiceGroup
        let task: Task<Void, Never>
        let port: Int
    }

    private var running: Running?

    public init() {}

    public var isRunning: Bool { self.running != nil }

    /// Port actually bound, once listening (useful when `port: 0` was requested).
    public var boundPort: Int? { self.running?.port }

    public func start(host: String = CullServer.defaultHost,
                      port: Int,
                      token: String,
                      staticRoot: URL? = nil,
                      backend: some CullBackend) async throws {
        guard self.running == nil else { throw CullServerError.alreadyRunning }
        guard !token.isEmpty else { throw CullServerError.emptyToken }

        let logger = Logger(label: "photocull.server")
        let signal = StartupSignal()
        let backend: any CullBackend = backend
        let application = Self.makeApplication(host: host, port: port, token: token,
                                               staticRoot: staticRoot, backend: backend,
                                               signal: signal, logger: logger)
        let group = ServiceGroup(services: [application], logger: logger)
        let task = Task {
            do {
                try await group.run()
            } catch {
                signal.fail(error)
            }
            signal.fail(CullServerError.stoppedBeforeStart)
        }

        do {
            let boundPort = try await signal.wait()
            self.running = Running(group: group, task: task, port: boundPort)
        } catch {
            await group.triggerGracefulShutdown()
            _ = await task.value
            throw error
        }
    }

    /// Stops listening and waits for in-flight requests to finish. Safe to call when stopped.
    public func stop() async {
        guard let running = self.running else { return }
        self.running = nil
        await running.group.triggerGracefulShutdown()
        _ = await running.task.value
    }
}

// MARK: - Application assembly

extension CullServer {
    private static func makeApplication(host: String,
                                        port: Int,
                                        token: String,
                                        staticRoot: URL?,
                                        backend: any CullBackend,
                                        signal: StartupSignal,
                                        logger: Logger) -> Application<RouterResponder<BasicRequestContext>> {
        let router = Router<BasicRequestContext>()
        router.add(middleware: JSONErrorMiddleware())
        if let staticRoot {
            router.add(middleware: StaticFilesMiddleware(root: staticRoot.path, logger: logger))
        }
        router.add(middleware: BearerTokenMiddleware(token: token))
        addRoutes(to: router, backend: backend)

        return Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port), serverName: "photocull"),
            onServerRunning: { channel in
                signal.succeed(channel.localAddress?.port ?? port)
            },
            logger: logger
        )
    }

    private static func addRoutes(to router: Router<BasicRequestContext>, backend: any CullBackend) {
        router.get("api/health") { _, _ in
            try jsonResponse(HealthResponse(name: backend.hostName))
        }

        router.get("api/sessions") { _, _ in
            let sessions = try await backend.listSessions()
            return try jsonResponse(SessionsResponse(sessions: sessions))
        }

        router.get("api/sessions/:date") { _, context in
            let date = try requiredParameter("date", context)
            let detail = try await backend.sessionDetail(date: date)
            return try jsonResponse(detail)
        }

        router.get("api/sessions/:date/photos/:stem/preview") { request, context in
            let date = try requiredParameter("date", context)
            let stem = try requiredParameter("stem", context)
            let asset = try await backend.preview(date: date, stem: stem)

            var headers = HTTPFields()
            headers[.eTag] = quotedETag(asset.etag)
            headers[.cacheControl] = "private, max-age=31536000, immutable"
            if let ifNoneMatch = request.headers[.ifNoneMatch], etagMatches(ifNoneMatch, asset.etag) {
                return Response(status: .notModified, headers: headers)
            }
            headers[.contentType] = "image/jpeg"
            return Response(status: .ok, headers: headers,
                            body: .init(byteBuffer: ByteBuffer(bytes: try bodyBytes(of: asset))))
        }

        router.post("api/sessions/:date/changes") { request, context in
            let date = try requiredParameter("date", context)
            let payload: ChangesBody = try decodeJSON(try await collectBody(request, maxBytes: maxBodyBytes))
            guard payload.changes.count <= maxChanges else {
                throw HTTPError(.badRequest, message: "too many changes (max \(maxChanges) per request)")
            }
            let changes = try payload.changes.map(validated)
            let detail = try await backend.applyChanges(date: date, changes: changes)
            return try jsonResponse(detail)
        }
    }
}

// MARK: - Request handling helpers

private func requiredParameter(_ name: String, _ context: BasicRequestContext) throws -> String {
    guard let value = context.parameters.get(name), !value.isEmpty else {
        throw HTTPError(.badRequest, message: "missing path parameter '\(name)'")
    }
    return value
}

private func jsonResponse<T: Encodable>(_ value: T,
                                        status: HTTPResponse.Status = .ok) throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    headers[.cacheControl] = "no-store"
    let encoded = try JSONEncoder().encode(value)
    return Response(status: status, headers: headers,
                    body: .init(byteBuffer: ByteBuffer(bytes: encoded)))
}

private struct ErrorBody: Encodable {
    let error: String
}

private func errorResponse(_ status: HTTPResponse.Status, _ message: String) throws -> Response {
    try jsonResponse(ErrorBody(error: message), status: status)
}

// MARK: - Request body decoding and validation

private struct ChangesBody: Decodable {
    var changes: [ChangePayload]
}

private struct ChangePayload: Decodable {
    enum Field: String, Decodable {
        case decision
        case rotation
    }

    enum Value: Decodable {
        case string(String)
        case number(Int)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "value must be a string or an integer")
            }
        }
    }

    var stem: String
    var field: Field
    var value: Value
    var at: Int64
}

private func collectBody(_ request: Request, maxBytes: Int) async throws -> Data {
    var total = 0
    var buffer = ByteBufferAllocator().buffer(capacity: 4096)
    for try await part in request.body {
        total += part.readableBytes
        guard total <= maxBytes else {
            throw HTTPError(.badRequest, message: "request body too large (max \(maxBytes) bytes)")
        }
        buffer.writeImmutableBuffer(part)
    }
    return Data(buffer.readableBytesView)
}

private func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch let error as DecodingError {
        throw HTTPError(.badRequest, message: decodingMessage(error))
    }
}

private func decodingMessage(_ error: DecodingError) -> String {
    switch error {
    case let .keyNotFound(key, _):
        return "missing field '\(key.stringValue)'"
    case let .valueNotFound(_, context):
        return "missing value at '\(context.codingPath.pathDescription)'"
    case let .typeMismatch(_, context):
        return "wrong type at '\(context.codingPath.pathDescription)'"
    case let .dataCorrupted(context):
        return "invalid JSON: \(context.debugDescription)"
    @unknown default:
        return "invalid JSON"
    }
}

private extension Array where Element == any CodingKey {
    var pathDescription: String {
        self.map(\.stringValue).joined(separator: ".")
    }
}

/// Turns one wire change into a typed, clock-clamped change, or throws a 400.
private func validated(_ payload: ChangePayload) throws -> SessionChange {
    guard !payload.stem.isEmpty else {
        throw HTTPError(.badRequest, message: "change stem must not be empty")
    }
    guard payload.at > 0 else {
        throw HTTPError(.badRequest, message: "at must be a positive Unix millisecond timestamp")
    }

    let value: SessionChange.Value
    switch payload.field {
    case .decision:
        guard case let .string(raw) = payload.value, let decision = DecisionValue(rawValue: raw) else {
            throw HTTPError(.badRequest, message: "decision value must be one of keep, reject, undecided")
        }
        value = .decision(decision)
    case .rotation:
        guard case let .number(turns) = payload.value else {
            throw HTTPError(.badRequest, message: "rotation value must be an integer")
        }
        guard (0...3).contains(turns) else {
            throw HTTPError(.badRequest, message: "rotation value must be 0, 1, 2 or 3")
        }
        value = .rotation(turns)
    }

    let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
    let at = min(payload.at, now + CullServer.maxClockSkewMillis)
    return SessionChange(stem: payload.stem, value: value, at: at)
}

// MARK: - Preview bytes and ETags

private func bodyBytes(of asset: PreviewAsset) throws -> Data {
    if let data = asset.data { return data }
    guard let url = asset.fileURL else {
        throw CullBackendError.failure("preview has no data")
    }
    do {
        return try Data(contentsOf: url)
    } catch {
        throw CullBackendError.failure("preview could not be read")
    }
}

/// Strips weak markers and quotes so callers may hand over either form.
private func normalizedETag(_ value: String) -> String {
    var tag = value.trimmingCharacters(in: .whitespaces)
    if tag.hasPrefix("W/") {
        tag.removeFirst(2)
        tag = tag.trimmingCharacters(in: .whitespaces)
    }
    if tag.count >= 2, tag.hasPrefix("\""), tag.hasSuffix("\"") {
        tag = String(tag.dropFirst().dropLast())
    }
    return tag
}

private func quotedETag(_ value: String) -> String {
    "\"\(normalizedETag(value))\""
}

private func etagMatches(_ ifNoneMatch: String, _ etag: String) -> Bool {
    let wanted = normalizedETag(etag)
    return ifNoneMatch.split(separator: ",").contains { candidate in
        let tag = normalizedETag(String(candidate))
        return tag == "*" || tag == wanted
    }
}

/// Compares byte-by-byte without an early exit so a token cannot be guessed by timing.
private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices {
        difference |= a[index] ^ b[index]
    }
    return difference == 0
}

// MARK: - Middleware

/// Converts every thrown error into the contract's `{"error": "..."}` body.
private struct JSONErrorMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            let (status, message) = Self.describe(error, logger: context.logger)
            return try errorResponse(status, message)
        }
    }

    private static func describe(_ error: any Error, logger: Logger) -> (HTTPResponse.Status, String) {
        switch error {
        case let error as CullBackendError:
            switch error {
            case let .badRequest(message): return (.badRequest, message)
            case let .notFound(message): return (.notFound, message)
            case let .locked(message): return (.conflict, message)
            case let .failure(message): return (.internalServerError, message)
            }
        case let error as HTTPError:
            return (error.status, error.body ?? error.status.reasonPhrase)
        case let error as any HTTPResponseError:
            return (error.status, error.status.reasonPhrase)
        case is DecodingError:
            return (.badRequest, "invalid JSON body")
        default:
            logger.error("unhandled API error: \(error)")
            return (.internalServerError, "internal error")
        }
    }
}

/// Static PWA files are public; every `/api` path needs the bearer token.
private struct BearerTokenMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        guard request.uri.path.hasPrefix("/api") else {
            return try await next(request, context)
        }
        guard let header = request.headers[.authorization],
              let supplied = Self.bearerToken(header),
              constantTimeEquals(supplied, self.token) else {
            return try errorResponse(.unauthorized, "missing or invalid bearer token")
        }
        return try await next(request, context)
    }

    private static func bearerToken(_ header: String) -> String? {
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// Serves `staticRoot` for non-`/api` paths without auth; `/api` paths fall through.
private struct StaticFilesMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let files: FileMiddleware<BasicRequestContext, LocalFileSystem>

    init(root: String, logger: Logger) {
        self.files = FileMiddleware(root, searchForIndexHtml: true, logger: logger)
    }

    func handle(_ request: Request, context: BasicRequestContext,
                next: (Request, BasicRequestContext) async throws -> Response) async throws -> Response {
        guard !request.uri.path.hasPrefix("/api") else {
            return try await next(request, context)
        }
        // Terminal: static files never fall through to routes.
        return try await self.files.handle(request, context: context) { _, _ in
            throw HTTPError(.notFound)
        }
    }
}

// MARK: - Startup handshake

/// Bridges "the listener is up" (or "startup failed") to an awaiting `start()`.
private final class StartupSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Int, any Error>?
    private var waiter: CheckedContinuation<Int, any Error>?

    func wait() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let result = self.result {
                self.lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.waiter = continuation
            self.lock.unlock()
        }
    }

    func succeed(_ port: Int) {
        self.resolve(.success(port))
    }

    func fail(_ error: any Error) {
        self.resolve(.failure(error))
    }

    private func resolve(_ outcome: Result<Int, any Error>) {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return
        }
        self.result = outcome
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume(with: outcome)
    }
}
