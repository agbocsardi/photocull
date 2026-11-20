import AppKit
import CoreImage
import Foundation
import IOKit.pwr_mgt
import PhotoCullCore
import Security

// RemoteCullSupport.swift — the Mac host pieces of "Cull from phone" that are
// neither UI nor the HTTP server itself:
//
//  - RemoteTokenStore: the 32-byte base64url pairing key. It lives in the login
//    Keychain under a service name scoped to the library mode, so a development
//    run can never read the installed app's key (and vice versa). It is never
//    written to config.toml. Fixture runs keep it in memory only.
//  - Tailscale: locate the CLI, read `status --json` and `serve status --json`
//    (read-only), and run `serve --bg` only when the owner clicks the button.
//  - QRCode: pairing URL → crisp NSImage through CIQRCodeGenerator.
//  - SleepAssertion: the IOPM "prevent idle system sleep" hold used while
//    serving.

// MARK: - Pairing token

/// The pairing key handed to the phone in the URL fragment. 32 random bytes,
/// base64url with no padding (43 characters).
enum RemoteTokenStore {
    static let account = "pairing"

    /// Keychain service for this library mode. Naming it after the mode keeps
    /// dev and real tokens apart even if a dev run somehow read the same
    /// Keychain; `nil` means "not persisted" (disposable fixture runs).
    static var service: String? {
        switch LibraryMode.current {
        case .real: return "local.photocull.remote.real"
        case .dev: return "local.photocull.remote.dev"
        case .fixture: return nil
        }
    }

    /// Fixture-mode key: in memory only, gone with the process.
    private static var fixtureToken: String?

    /// The stored key, or a fresh one saved for next launch. `nil` only if the
    /// system random generator failed, which should never happen.
    static func loadOrCreate() -> String? {
        if service == nil {
            if let fixtureToken { return fixtureToken }
            let fresh = generate()
            fixtureToken = fresh
            return fresh
        }
        if let saved = readKeychain() { return saved }
        guard let fresh = generate() else { return nil }
        _ = writeKeychain(fresh)
        return fresh
    }

    /// Replace the key: every phone paired with the old one is invalidated.
    static func regenerate() -> String? {
        guard let fresh = generate() else { return nil }
        if service == nil {
            fixtureToken = fresh
            return fresh
        }
        deleteKeychain()
        _ = writeKeychain(fresh)
        return fresh
    }

    /// 32 random bytes as unpadded base64url.
    static func generate() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return base64url(Data(bytes))
    }

    /// Unpadded base64url, the encoding the API contract specifies.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Keychain (generic password, default login keychain)

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readKeychain() -> String? {
        guard let service else { return nil }
        var query = query(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    private static func writeKeychain(_ token: String) -> Bool {
        guard let service else { return false }
        deleteKeychain()
        var attributes = query(service: service)
        attributes[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteKeychain() {
        guard let service else { return }
        _ = SecItemDelete(query(service: service) as CFDictionary)
    }
}

// MARK: - Tailscale

/// What `tailscale status --json` says about this Mac. Read-only: the CLI is
/// never asked to change anything here.
struct TailscaleInfo: Equatable, Sendable {
    var cliPath: String?
    /// `BackendState`, e.g. "Running", "Stopped", "NeedsLogin".
    var backendState: String?
    /// MagicDNS name without its trailing dot.
    var dnsName: String?
    var online: Bool

    init(cliPath: String? = nil, backendState: String? = nil,
         dnsName: String? = nil, online: Bool = false) {
        self.cliPath = cliPath
        self.backendState = backendState
        self.dnsName = dnsName
        self.online = online
    }

    var installed: Bool { cliPath != nil }
    var running: Bool { backendState == "Running" }
    /// The phone-facing host name, or nil when MagicDNS is not available.
    var magicDNSName: String? {
        guard let dnsName, !dnsName.isEmpty else { return nil }
        return dnsName
    }
}

/// The `tailscale serve` handler that fronts this machine, from
/// `tailscale serve status --json`. `.unknown` means the CLI was missing or the
/// read failed — not "nothing configured".
enum ServeConfiguration: Equatable, Sendable {
    case unknown
    case none
    case proxy(String)

    var proxyURL: String? {
        if case .proxy(let url) = self { return url }
        return nil
    }

    var port: Int? {
        guard let url = proxyURL, let parsed = URL(string: url) else { return nil }
        return parsed.port
    }

    func serves(port: Int) -> Bool { self.port == port }
}

enum ServeSetupResult: Equatable, Sendable {
    case success
    case failed(String)
}

enum Tailscale {
    /// The CLI locations Tailscale documents for the standalone app, Homebrew
    /// and the installer, in that order.
    static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    static func locate() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Exactly the command docs/REMOTE-CULL.md specifies, as arguments.
    static func serveArguments(port: Int) -> [String] {
        ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"]
    }

    /// The same command as text, for copying into a terminal.
    static func serveCommandText(port: Int) -> String {
        (["tailscale"] + serveArguments(port: port)).joined(separator: " ")
    }

    /// `tailscale status --json`, off the main thread.
    static func info() async -> TailscaleInfo {
        await Task.detached(priority: .userInitiated) { blockingInfo() }.value
    }

    /// `tailscale serve status --json`, off the main thread. Read-only.
    static func serveConfiguration() async -> ServeConfiguration {
        await Task.detached(priority: .utility) { blockingServeConfiguration() }.value
    }

    /// Runs `tailscale serve --bg --https=443 http://127.0.0.1:<port>`.
    /// Only called from the owner's confirmation in Settings — never on launch,
    /// never in a headless check.
    static func enableServe(cli: String, port: Int) async -> ServeSetupResult {
        await Task.detached(priority: .userInitiated) { () -> ServeSetupResult in
            let result = execute(cli, serveArguments(port: port))
            guard result.status == 0 else {
                let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failed(message.isEmpty
                    ? "tailscale serve exited with status \(result.status)."
                    : message)
            }
            return .success
        }.value
    }

    // MARK: Parsing (also exercised by the throwaway headless check)

    static func parse(status json: Data, cliPath: String?) -> TailscaleInfo {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return TailscaleInfo(cliPath: cliPath)
        }
        let selfNode = root["Self"] as? [String: Any]
        var dns = (selfNode?["DNSName"] as? String) ?? ""
        if dns.hasSuffix(".") { dns.removeLast() }
        return TailscaleInfo(cliPath: cliPath,
                             backendState: root["BackendState"] as? String,
                             dnsName: dns.isEmpty ? nil : dns,
                             online: (selfNode?["Online"] as? Bool) ?? false)
    }

    static func parse(serve json: Data) -> ServeConfiguration {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return .unknown
        }
        let web = root["Web"] as? [String: Any] ?? [:]
        for host in web.keys.sorted() where host.hasSuffix(":443") {
            let handlers = (web[host] as? [String: Any])?["Handlers"] as? [String: Any]
            if let proxy = (handlers?["/"] as? [String: Any])?["Proxy"] as? String {
                return .proxy(proxy)
            }
        }
        return .none
    }

    // MARK: CLI

    private static func blockingInfo() -> TailscaleInfo {
        guard let cli = locate() else { return TailscaleInfo() }
        let result = execute(cli, ["status", "--json"])
        guard result.status == 0 else { return TailscaleInfo(cliPath: cli) }
        return parse(status: Data(result.output.utf8), cliPath: cli)
    }

    private static func blockingServeConfiguration() -> ServeConfiguration {
        guard let cli = locate() else { return .unknown }
        let result = execute(cli, ["serve", "status", "--json"])
        guard result.status == 0 else { return .unknown }
        return parse(serve: Data(result.output.utf8))
    }

    /// Blocking process run. stdout and stderr share one pipe: every caller
    /// either parses JSON (which only happens on success) or shows the text.
    private static func execute(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - QR code

enum QRCode {
    /// Modules are drawn at an integer pixel scale, so no module is ever
    /// resampled and the code stays crisp at the size Settings shows it.
    static let pixelScale = 12

    /// A black-on-white QR image for `text`, or nil if CoreImage can't build it.
    static func image(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let context = CIContext()
        guard let base = context.createCGImage(output, from: output.extent) else { return nil }

        let width = base.width * pixelScale
        let height = base.height * pixelScale
        guard let canvas = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // White quiet zone as well as modules: the generator itself is
        // black-on-transparent, which would vanish on a dark panel.
        canvas.interpolationQuality = .none
        canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = canvas.makeImage() else { return nil }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(NSBitmapImageRep(cgImage: scaled))
        return image
    }
}

// MARK: - Power

/// Holds the "prevent idle system sleep" assertion while the embedded server is
/// up. The kernel drops it when the process exits; `release()` also drops it as
/// soon as serving stops.
final class SleepAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var id: IOPMAssertionID = 0

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return id != 0
    }

    /// Take the assertion (idempotent). Returns whether it is held afterwards.
    @discardableResult
    func adopt(reason: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if id != 0 { return true }
        var fresh: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &fresh)
        guard result == kIOReturnSuccess else { return false }
        id = fresh
        return true
    }

    func release() {
        lock.lock()
        let current = id
        id = 0
        lock.unlock()
        if current != 0 { IOPMAssertionRelease(current) }
    }
}
