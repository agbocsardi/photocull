import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PhotoCullCore
import PhotoCullHost
import PhotoCullServer

// photocull-serve — the home-server host for PhotoCull (docs/REMOTE-CULL.md §6).
//
// One library, one listener on loopback, the same CullServer + CoreCullBackend
// the Mac app's embedded API uses. The mode gate runs first: DEV (default, the
// throwaway dev library) or an explicit, owner-marked REAL data root. Nothing
// here creates a library folder, and the token is never logged.

func log(_ message: String) {
    FileHandle.standardError.write(Data("photocull-serve: \(message)\n".utf8))
}

/// Resolves once SIGINT or SIGTERM arrives. Dispatch sources need their signals
/// ignored first, otherwise the default action would kill the process before
/// the server could stop in order.
final class TerminationSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let sources: [DispatchSourceSignal]

    init() {
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [semaphore] in semaphore.signal() }
            source.resume()
            sources.append(source)
        }
        self.sources = sources
    }

    func wait() async {
        let semaphore = self.semaphore
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}

/// Runs until a termination signal, then stops the listener.
func run(_ options: ServeOptions) async throws {
    let library = try ServeGate.resolve(options)
    let token = try ServeGate.readToken(at: options.tokenFile ?? "")
    let pwa = try ServeGate.pwaRoot(options)
    let termination = TerminationSignal()

    log("mode \(library.mode == .real ? "REAL" : "DEV")")
    log("data root \(library.root)")
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: library.cfg.paths.inbox, isDirectory: &isDirectory),
       isDirectory.boolValue {
        log("inbox \(library.cfg.paths.inbox)")
    } else {
        log("inbox \(library.cfg.paths.inbox) does not exist; serving an empty session list")
    }

    let server = CullServer()
    do {
        try await server.start(host: CullServer.defaultHost,
                               port: options.port,
                               token: token,
                               staticRoot: pwa,
                               backend: CoreCullBackend(cfg: library.cfg,
                                                        hostName: ProcessInfo.processInfo.hostName))
    } catch {
        throw StartupError("could not start the server: \(error)")
    }

    let boundPort = await server.boundPort ?? options.port
    log("listening on http://\(CullServer.defaultHost):\(boundPort)")
    if let pwa {
        log("serving PWA from \(pwa.path)")
    } else {
        log("API only")
    }

    await termination.wait()
    log("stopping")
    await server.stop()
}

do {
    let options = try ServeOptions.parse(CommandLine.arguments)
    if options.help {
        print(ServeOptions.usage)
        exit(0)
    }
    try await run(options)
} catch let error as ServeOptions.UsageError {
    log(error.description)
    FileHandle.standardError.write(Data((ServeOptions.usage + "\n").utf8))
    exit(2)
} catch let error as StartupError {
    log(error.description)
    exit(1)
} catch {
    log("\(error)")
    exit(1)
}
