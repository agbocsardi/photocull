import AppKit
import Foundation
import PhotoCullCore

// RemoteCull.swift — the Mac host's "Cull from phone" model.
//
// The UI and the persisted pairing key live here; the HTTP server does not.
// Wave 2 installs the real server through `hooks`:
//
//     RemoteCull.shared.hooks = .init(
//         start: { port, token in try await PhotoCullServer.start(port: port, token: token) },
//         stop:  { await PhotoCullServer.stop() })
//     await RemoteCull.shared.resumeIfEnabled()   // once, at launch
//
// Until then the default hooks do nothing, so the panel builds and behaves but
// reports serving without a listener behind it (only reachable from Settings).
//
// Everything here is scoped by `LibraryMode`: dev runs use the dev Keychain
// service and the dev preferences suite, so they can never read or write the
// installed app's token, enabled flag or port.

@MainActor
final class RemoteCull: ObservableObject {
    /// The server the wiring step provides. Start must be idempotent and throw
    /// if the port cannot be bound; stop must tolerate not running.
    struct ServerHooks {
        var start: (Int, String) async throws -> Void
        var stop: () async -> Void

        static let unavailable = ServerHooks(start: { _, _ in }, stop: {})
    }

    static let shared = RemoteCull()
    static let defaultPort = 8723
    private static let enabledKey = "PhotoCull.remote.enabled"
    private static let portKey = "PhotoCull.remote.port"
    private static let sleepReason = "PhotoCull is serving your photo library to your phone"

    enum Status: Equatable {
        case off
        case starting
        case serving
        case error(String)
    }

    @Published private(set) var status: Status
    /// The owner's switch. Flipped immediately so the Toggle does not bounce;
    /// a failed start flips it back and leaves the reason in `status`.
    @Published private(set) var enabled: Bool
    /// A transition is in flight: start, stop or re-key.
    @Published private(set) var busy: Bool
    /// Loopback port for the embedded API.
    @Published private(set) var port: Int
    /// The pairing key handed out in the URL fragment.
    @Published private(set) var token: String
    @Published private(set) var tailscale = TailscaleInfo()
    @Published private(set) var serve = ServeConfiguration.unknown
    /// Last result of the "Set up HTTPS with Tailscale" action (or its error).
    @Published private(set) var serveNote: String?

    var hooks = ServerHooks.unavailable

    /// Process-wide, so quitting can release it without creating this model.
    private nonisolated static let idleSleep = SleepAssertion()
    /// Whether to start serving at launch, remembered across launches.
    private var launchEnabled: Bool
    private var qrCache: (text: String, image: NSImage)?

    init() {
        status = .off
        enabled = false
        busy = false
        token = RemoteTokenStore.loadOrCreate() ?? ""
        port = Self.storedPort()
        launchEnabled = Self.storedEnabled()
    }

    // MARK: - Derived

    /// Dev and fixture runs serve the throwaway library; the panel says so.
    var isDevelopmentLibrary: Bool { LibraryMode.current != .real }

    /// `https://<magicdns>/#token=<token>` when Tailscale knows this Mac's
    /// name. The PWA needs HTTPS, so there is no local-network alternative.
    var pairingURL: String? {
        guard let name = tailscale.magicDNSName, !token.isEmpty else { return nil }
        return "https://\(name)/#token=\(token)"
    }

    /// `tailscale serve --bg --https=443 http://127.0.0.1:<port>`.
    var serveCommand: String { Tailscale.serveCommandText(port: port) }

    /// Cached QR image for the current pairing URL.
    var qrImage: NSImage? {
        guard let url = pairingURL else { return nil }
        if let cached = qrCache, cached.text == url { return cached.image }
        guard let image = QRCode.image(for: url) else { return nil }
        qrCache = (url, image)
        return image
    }

    // MARK: - Serving

    /// Toggle entry point. Synchronous so the switch moves at once; the hooks
    /// run in a task that `busy` guards against overlap.
    func setEnabled(_ on: Bool) {
        guard !busy, on != enabled else { return }
        guard !on || !token.isEmpty else {
            status = .error("No pairing key is available.")
            return
        }
        enabled = on
        status = on ? .starting : .off
        serveNote = nil
        busy = true
        Task { await applyEnabled(on) }
    }

    private func applyEnabled(_ on: Bool) async {
        if on {
            await beginServing()
        } else {
            await hooks.stop()
            Self.idleSleep.release()
            setLaunchEnabled(false)
        }
        busy = false
    }

    private func beginServing() async {
        do {
            try await hooks.start(port, token)
            Self.idleSleep.adopt(reason: Self.sleepReason)
            status = .serving
            setLaunchEnabled(true)
        } catch {
            enabled = false
            status = .error(error.localizedDescription)
            setLaunchEnabled(false)
        }
    }

    /// Start on launch when the owner left this on. Wave 2 calls this once,
    /// after installing real hooks; the default hooks stay off.
    func resumeIfEnabled() async {
        guard launchEnabled, !enabled, !busy, !token.isEmpty else { return }
        enabled = true
        status = .starting
        busy = true
        await beginServing()
        busy = false
    }

    /// Accepts any editable port while the field is being typed; a privileged
    /// port simply fails to bind when serving starts.
    func setPort(_ value: Int) {
        guard !enabled, (1...65535).contains(value), value != port else { return }
        port = value
        guard LibraryMode.current != .fixture else { return }
        AppDefaults.store.set(String(port), forKey: Self.portKey)
    }

    /// Replace the pairing key; every already-paired phone stops working.
    func resetPairing() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let fresh = RemoteTokenStore.regenerate() else {
            if !enabled { status = .error("Could not create a pairing key.") }
            return
        }
        let wasServing = enabled
        if wasServing {
            await hooks.stop()
            Self.idleSleep.release()
            status = .starting
        }
        token = fresh
        qrCache = nil
        if wasServing {
            await beginServing()
        }
    }

    /// Release the idle-sleep hold. Called when the app terminates; static so
    /// quitting never has to build the model (which would touch the Keychain).
    nonisolated static func releaseIdleSleep() { idleSleep.release() }

    // MARK: - Tailscale

    /// Refresh status and the existing Serve configuration, off the main thread.
    func refreshTailscale() async {
        async let info = Tailscale.info()
        async let configuration = Tailscale.serveConfiguration()
        tailscale = await info
        serve = await configuration
    }

    /// Run `tailscale serve` for this port. Only from the owner's confirmation.
    func enableServeWithTailscale() async {
        guard let cli = tailscale.cliPath else {
            serveNote = "Tailscale is not installed."
            return
        }
        serveNote = "Running tailscale serve…"
        let result = await Tailscale.enableServe(cli: cli, port: port)
        switch result {
        case .success:
            let host = tailscale.magicDNSName ?? "this Mac"
            serveNote = "Tailscale Serve now forwards https://\(host)/ to 127.0.0.1:\(port)."
        case .failed(let message):
            serveNote = message
        }
        await refreshTailscale()
    }

    // MARK: - Persistence

    private static func storedPort() -> Int {
        guard LibraryMode.current != .fixture,
              let raw = AppDefaults.store.string(forKey: portKey),
              let value = Int(raw), (1...65535).contains(value) else { return defaultPort }
        return value
    }

    private static func storedEnabled() -> Bool {
        guard LibraryMode.current != .fixture else { return false }
        return AppDefaults.store.string(forKey: enabledKey) == "1"
    }

    private func setLaunchEnabled(_ on: Bool) {
        launchEnabled = on
        guard LibraryMode.current != .fixture else { return }
        AppDefaults.store.set(on ? "1" : "0", forKey: Self.enabledKey)
    }
}
