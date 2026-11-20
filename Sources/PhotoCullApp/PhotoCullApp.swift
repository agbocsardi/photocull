import SwiftUI
import AppKit
import PhotoCullCore
import PhotoCullHost

@main
enum PhotoCullMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        do {
            StartupConfiguration.current = try StartupConfiguration.resolve(
                arguments: Array(args.dropFirst()), bundleIdentifier: Bundle.main.bundleIdentifier)
        } catch {
            FileHandle.standardError.write(Data("PhotoCull: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
        // Data-safety gate, decided once, before any config is loaded or
        // AppState exists. Fixture mode (resolved above) takes precedence;
        // otherwise REAL is only the installed /Applications (or
        // ~/Applications) bundle - every other executable is DEV and can
        // never reach the real library or real config.
        LibraryMode.current = StartupConfiguration.current.isFixture
            ? .fixture
            : LibraryMode.detect(bundleIdentifier: Bundle.main.bundleIdentifier,
                                  bundlePath: Bundle.main.bundleURL.path)
        if args.contains("--repair-pairs") {
            exit(HeadlessCheck.repairPairs(apply: args.contains("--apply")))
        }
        if args.contains("--check") {
            exit(HeadlessCheck.run())
        }
        PhotoCullApp.main()
    }
}

struct PhotoCullApp: App {
    @StateObject private var app = StartupConfiguration.current.makeAppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(connectedApp)
                .environmentObject(app.imageLoader)
                .environmentObject(app.canvas)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1400, height: 880)
        // Unified toolbar: the app title and actions live in the real title bar,
        // so the traffic lights and the drag zone behave natively.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button("Show Info Inspector") { app.toggleInspector() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandMenu("Cull") {
                Button("Ingest from SD Card…") { app.beginIngest() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Finalize Current Session…") { app.beginFinalizeCurrent() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(app.activeDate == nil)
                Button("Finalize Selected Sessions…") { app.beginGlobalFinalize() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(app.sessions.isEmpty)
                Divider()
                Button("Crop Current Photo") { app.enterCropMode() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(app.currentPair == nil)
                Button("Open in Preview") { app.openInPreview() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(app.currentPair == nil)
                Button("Reveal in Finder") { app.revealInFinder() }
                    .disabled(app.currentPair == nil)
                Divider()
                Button("Reload Inbox") { app.reloadLibrary() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Check RAW Pairing") { app.checkPairing() }
                    .disabled(app.sessions.isEmpty)
                Button("Re-pair RAW Files…") { app.repairPairingInteractive() }
                    .disabled(app.sessions.isEmpty)
                Button("Remove Empty Sessions…") { app.beginRemoveEmptySessions() }
                    .disabled(!app.canRemoveEmptySessions || !app.sessions.contains { $0.total == 0 })
                    .help("Remove finalized session folders that hold only their sidecar")
            }
            // The standard “PhotoCull Help” search item is replaced by the
            // app's own guide — the Controls sheet already answers “which key?”.
            CommandGroup(replacing: .help) {
                Button("PhotoCull Getting Started") { app.modal = .guide }
                    .help("What PhotoCull is, the workflow, and where files live")
            }
        }

        // The real macOS settings window (⌘,): Folders / Files / Finalize /
        // General tabs, edited as a draft and applied through updateConfig.
        Settings {
            SettingsRoot()
                .environmentObject(connectedApp)
        }

        // Its ordinary menu contains a direct Finder action; do not insert it in fixture mode.
        MenuBarExtra(isInserted: .constant(!app.fixtureMode)) {
            MenuBarView()
                .environmentObject(connectedApp)
        } label: {
            // A single image is reliable in MenuBarExtra's status-item renderer.
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor private var connectedApp: AppState {
        delegate.operationState = app
        RemoteCullWiring.installOnce(app: app)
        return app
    }

    private static let menuBarIcon: NSImage = {
        let bundled = Bundle.main.url(forResource: "PhotoCullMenuBar", withExtension: "png")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("resources/PhotoCullMenuBar.png")
        if let icon = bundled.flatMap({ NSImage(contentsOf: $0) })
            ?? NSImage(contentsOf: development) {
            // A transparent, monochrome 36px image displayed at 18pt.
            // Template tint follows the system's light or dark menu bar.
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            return icon
        }
        return NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "PhotoCull")!
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var operationState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard operationState?.prepareForTermination() != false else { return .terminateCancel }
        guard RemoteCullWiring.installed else { return .terminateNow }
        // Release the phone API's loopback listener before the process goes away.
        Task { @MainActor in
            await RemoteCullWiring.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        KeyMonitor.shared.start()
        if !StartupConfiguration.current.isFixture {
            Snapshot.applyRequestedAppearance()
            Snapshot.scheduleIfRequested()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Cull from phone holds an idle-sleep assertion; drop it before the process goes away.
    func applicationWillTerminate(_ notification: Notification) {
        RemoteCull.releaseIdleSleep()
    }
}

/// Brings the embedded HTTP API up behind the "Cull from phone" panel.
///
/// Lives in the entry-point file on purpose: the headless check harnesses
/// compile every other app source without PhotoCullHost, so the app module
/// proper (AppState, RemoteCull, …) stays free of the server dependency.
@MainActor
enum RemoteCullWiring {
    /// The listener lives for the process; only the panel's hooks reach it.
    private static let server = CullServerHost()
    /// The app's current, mode-gated config — the server's only library.
    private static var config: PCConfig?
    private(set) static var installed = false

    /// Called once the window exists (the first view body evaluation); starts
    /// serving again if the owner left "Cull from phone" on.
    static func installOnce(app: AppState) {
        guard !installed, !app.fixtureMode, Snapshot.requestedPath == nil else { return }
        installed = true
        config = app.cfg
        RemoteCull.shared.hooks = .init(
            start: { port, token in
                guard let cfg = config else { throw CullServerHost.HostError.notConfigured }
                try await server.start(cfg: cfg, port: port, token: token)
            },
            stop: { await server.stop() })
        // Settings can repoint the library while serving: never keep answering
        // from the folders the app has left behind.
        app.configDidApply = { [weak app] applied in
            config = applied
            Task { @MainActor in
                do { try await server.reconfigure(cfg: applied) }
                catch { app?.toastMessage("Could not restart the phone server: \(error.localizedDescription)") }
            }
        }
        Task { await RemoteCull.shared.resumeIfEnabled() }
    }

    static func shutdown() async {
        await server.stop()
    }
}
