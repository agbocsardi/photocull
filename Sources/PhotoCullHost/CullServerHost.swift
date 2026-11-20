import Foundation
import PhotoCullCore
import PhotoCullServer

// CullServerHost.swift — the Mac app's embedded API listener (docs/REMOTE-CULL.md §5).
//
// One CullServer on loopback, bound to whatever `PCConfig` the app resolved
// through `LibraryMode`. It is rebuilt whenever that config changes, so it can
// never keep serving a library the app no longer points at.

public actor CullServerHost {
    public enum HostError: Error, LocalizedError, Equatable {
        case notConfigured
        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "Cull from phone has no library to serve."
            }
        }
    }

    private struct Running {
        var server: CullServer
        var cfg: PCConfig
        var port: Int
        var token: String
    }

    private var running: Running?
    private let hostName: String

    public init(hostName: String = ProcessInfo.processInfo.hostName) {
        self.hostName = hostName
    }

    public var isServing: Bool { running != nil }

    /// Starts serving `cfg` on `127.0.0.1:port`. Replaces a previous listener
    /// (same library or not) so the port and token are the ones just handed in.
    public func start(cfg: PCConfig, port: Int, token: String, staticRoot: URL? = nil) async throws {
        await stop()
        let server = CullServer()
        try await server.start(host: CullServer.defaultHost,
                               port: port,
                               token: token,
                               staticRoot: staticRoot ?? PWAStaticRoot.resolve(),
                               backend: CoreCullBackend(cfg: cfg, hostName: hostName))
        running = Running(server: server, cfg: cfg, port: port, token: token)
    }

    /// Point a running listener at a new config (Settings changed the folders):
    /// same port, same token, fresh backend. A no-op when nothing is serving —
    /// the next `start` picks the new config up by itself.
    public func reconfigure(cfg: PCConfig) async throws {
        guard let current = running, current.cfg != cfg else { return }
        running = nil
        await current.server.stop()
        try await start(cfg: cfg, port: current.port, token: current.token)
    }

    public func stop() async {
        guard let current = running else { return }
        running = nil
        await current.server.stop()
    }
}

/// Where the phone web app is served from.
///
/// The installed app serves its bundled copy only. Development runs (any
/// non-REAL mode: `swift run`, `.build/*/PhotoCull`, `dist/PhotoCull.app`) also
/// fall back to this checkout's `pwa/`, so editing the web app needs no rebuild.
/// With no PWA at all the API still serves; only the web app is missing.
public enum PWAStaticRoot {
    public static func resolve(mode: LibraryMode = LibraryMode.current) -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("pwa"),
           isDirectory(bundled) {
            return bundled
        }
        guard mode != .real else {
            note("no bundled pwa/ — serving the API only")
            return nil
        }
        // Sources/PhotoCullHost/CullServerHost.swift → repository root.
        let repoPWA = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pwa")
        if isDirectory(repoPWA) { return repoPWA }
        note("pwa/ not found — serving the API only")
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// A GUI app has no interesting stderr; still, the Console log is where a
    /// developer looks when the phone shows a blank page.
    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("photocull: \(message)\n".utf8))
    }
}
