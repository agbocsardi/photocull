import AppKit
import PhotoCullCore
import SwiftUI

// RemoteCullPanel.swift — Settings ▸ Cull from phone.
//
// The panel only drives `RemoteCull`; the embedded server itself is injected
// (see RemoteCull.ServerHooks). Order follows what the owner needs to do:
// turn it on, make HTTPS work with Tailscale, scan the code.

struct RemoteCullPanel: View {
    @ObservedObject var remote: RemoteCull
    @StateObject private var ui = ViewState(UiState())

    private struct UiState {
        var confirmation: Confirmation = .none
    }

    private enum Confirmation { case none, serve, resetPairing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionGap) {
                servingSection
                if remote.isDevelopmentLibrary {
                    developmentNote
                }
                if remote.enabled {
                    pairingSection
                }
                tailscaleSection
                footerNote
            }
            .padding(Metric.sheetPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await remote.refreshTailscale() }
        .alert("Set up HTTPS with Tailscale?", isPresented: isPresented(.serve)) {
            Button("Cancel", role: .cancel) {}
            Button("Run tailscale serve") {
                Task { await remote.enableServeWithTailscale() }
            }
        } message: {
            Text(serveConfirmation)
        }
        .alert("Reset pairing?", isPresented: isPresented(.resetPairing)) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Pairing Key", role: .destructive) {
                Task { await remote.resetPairing() }
            }
        } message: {
            Text("Phones that are already paired stop working. Scan the new code to pair again. "
                 + "The key is stored in your Keychain, never in config.toml.")
        }
    }

    // MARK: Serving

    private var servingSection: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap) {
            Text("Cull from your phone")
                .font(Typo.title3)
                .foregroundStyle(Palette.label)
            Text("Review and rate photos from a phone on your tailnet. The photos stay on this Mac: "
                 + "the phone reads previews and sends decisions back.")
                .font(Typo.callout)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Cull from phone", isOn: Binding(
                get: { remote.enabled },
                set: { remote.setEnabled($0) }))
                .font(Typo.body)
                .disabled(remote.busy)
                .padding(.top, Metric.elementGap / 2)
                .help("Serve this library to a phone through Tailscale.")
            statusLine
            if let note = remote.pairingNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            portRow
        }
    }

    private var statusLine: some View {
        HStack(spacing: Metric.elementGap - 2) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(Typo.callout)
                .foregroundStyle(statusTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var portRow: some View {
        HStack(spacing: Metric.elementGap) {
            Text("Port")
                .font(Typo.caption)
                .foregroundStyle(Palette.tertiary)
            TextField("8723", value: Binding(
                get: { remote.port },
                set: { remote.setPort($0) }), format: .number)
                .textFieldStyle(.roundedBorder)
                .font(Typo.mono)
                .frame(width: 76)
                .disabled(remote.enabled || remote.busy)
                .help("Loopback port for the phone API. The default 8723 is only changed when it is taken.")
            Text(remote.enabled
                 ? "Stop serving to change the port."
                 : "Only change this when 8723 is taken on this Mac.")
                .font(Typo.caption)
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var developmentNote: some View {
        Label("Development library — this serves \(PCConfig.abbreviateHome(LibraryMode.devRoot)) "
              + "and never your real photos.",
              systemImage: "hammer")
            .font(Typo.callout)
            .foregroundStyle(Palette.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap) {
            Text("Pair your phone")
                .font(Typo.headline)
                .foregroundStyle(Palette.label)

            if let image = remote.qrImage, let url = remote.pairingURL {
                HStack(alignment: .top, spacing: Metric.paneInset) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 176, height: 176)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous))
                        .hairlineBorder()

                    VStack(alignment: .leading, spacing: Metric.elementGap) {
                        Text(url)
                            .font(Typo.mono)
                            .foregroundStyle(Palette.label)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Copy URL") { copyToPasteboard(url) }
                            .help("Copy the pairing address, including the key.")
                        Text("Scan the code or open the address on a phone signed in to your tailnet. "
                             + "The code contains the pairing key, so keep it off shared screenshots.")
                            .font(Typo.caption)
                            .foregroundStyle(Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Reset Pairing…") { ui.value.confirmation = .resetPairing }
                            .disabled(remote.busy)
                            .help("Invalidate the current key and show a new code.")
                            .padding(.top, 2)
                    }
                }
                .padding(Metric.sheetGroupPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                        .fill(Palette.content)
                )
                .hairlineBorder()
            } else if remote.tailscale.installed {
                Text("Pairing needs this Mac’s Tailscale name. Open Tailscale, wait until it is connected, then refresh below.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Install Tailscale on this Mac first — the pairing address uses its HTTPS name.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Tailscale

    private var tailscaleSection: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap) {
            Text("Phone access (Tailscale)")
                .font(Typo.headline)
                .foregroundStyle(Palette.label)

            InspectorRow(label: "Status", value: tailscaleText,
                         tint: remote.tailscale.running ? Palette.keep : Palette.secondary)
            InspectorRow(label: "MagicDNS", value: remote.tailscale.magicDNSName ?? "—", mono: true)
            InspectorRow(label: "HTTPS", value: httpsText,
                         tint: remote.httpsReady ? Palette.keep : Palette.secondary)

            Text("PhotoCull keeps the API on 127.0.0.1. Tailscale Serve adds the certificate on "
                 + "port \(Tailscale.httpsPort) of this Mac's tailnet name and forwards it to "
                 + "PhotoCull. Nothing is exposed to the public internet.")
                .font(Typo.caption)
                .foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if remote.httpsPortConflict {
                Label(conflictNote, systemImage: "exclamationmark.triangle")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Metric.elementGap) {
                Button("Set up HTTPS with Tailscale") { ui.value.confirmation = .serve }
                    .disabled(!canSetUpHTTPS)
                    .help(setupHelp)
                Button("Copy Command") { copyToPasteboard(remote.serveCommand) }
                    .help("Copy the command to run it in Terminal yourself.")
                Spacer(minLength: 0)
                Button("Refresh") { Task { await remote.refreshTailscale() } }
                    .help("Check Tailscale again.")
            }

            Text(remote.serveCommand)
                .font(Typo.mono)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let note = remote.serveNote {
                Text(note)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !remote.tailscale.installed {
                Text("Install Tailscale on this Mac and on your phone, sign in to the same tailnet, "
                     + "then refresh. There is no local-network fallback: the phone app needs HTTPS.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !remote.tailscale.running {
                Text("Tailscale is installed but not connected. Open it and sign in, then refresh.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
            Label("The Mac must stay on and awake while you cull.", systemImage: "power")
                .font(Typo.callout)
                .foregroundStyle(Palette.secondary)
            if remote.status == .serving && remote.holdsSleepAssertion {
                Label("Mac stays awake while serving.", systemImage: "moon.zzz")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.tertiary)
            } else if remote.status == .serving {
                Label("Could not keep this Mac awake — turn off idle sleep in Energy settings.",
                      systemImage: "moon.zzz")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if remote.holdsSleepAssertion {
                Text("While serving, other Mac apps may notice this Mac does not idle-sleep. "
                     + "Turning Cull from phone off, or quitting PhotoCull, releases that hold.")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Text

    private var statusText: String {
        switch remote.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .serving: return "Serving on 127.0.0.1:\(remote.port)"
        case .error(let message): return message
        }
    }

    private var statusColor: Color {
        switch remote.status {
        case .off: return Palette.tertiary
        case .starting: return Palette.warning
        case .serving: return Palette.keep
        case .error: return Palette.reject
        }
    }

    private var statusTextColor: Color {
        switch remote.status {
        case .off: return Palette.secondary
        case .starting, .serving: return Palette.label
        case .error: return Palette.reject
        }
    }

    private var tailscaleText: String {
        let info = remote.tailscale
        guard info.installed else { return "Not installed" }
        guard let state = info.backendState else { return "Not running" }
        switch state {
        case "Running": return info.online ? "Connected" : "Running"
        case "NeedsLogin": return "Not signed in"
        case "NeedsMachineAuth": return "Waiting for approval"
        case "Stopped": return "Stopped"
        default: return state
        }
    }

    private var httpsText: String {
        switch remote.serve {
        case .unknown:
            return "Status unavailable"
        case .none:
            return "Not set up"
        case .proxy(let url):
            return remote.httpsReady ? "HTTPS ready" : "Port \(Tailscale.httpsPort) forwards \(url)"
        case .tcp(let target):
            return "Port \(Tailscale.httpsPort) is taken\(target.map { " by \($0)" } ?? "")"
        }
    }

    /// Something other than PhotoCull answers on the dedicated HTTPS port.
    private var conflictNote: String {
        "Port \(Tailscale.httpsPort) is already used on this Mac. PhotoCull will not overwrite it; "
            + "free that port (or remove its handler) before setting up HTTPS."
    }

    private var canSetUpHTTPS: Bool {
        remote.enabled && remote.tailscale.cliPath != nil && remote.tailscale.running
            && remote.tailscale.magicDNSName != nil
            && !remote.httpsReady && !remote.httpsPortConflict
    }

    private var setupHelp: String {
        if !remote.enabled { return "Turn on Cull from phone first." }
        if remote.httpsReady { return "HTTPS is already set up on port \(Tailscale.httpsPort)." }
        if remote.httpsPortConflict {
            return "Port \(Tailscale.httpsPort) is already used by another service on this Mac."
        }
        return "Run tailscale serve for this port."
    }

    private var serveConfirmation: String {
        let host = remote.tailscale.magicDNSName ?? "this Mac"
        return "PhotoCull runs:\n\n\(remote.serveCommand)\n\n"
            + "This adds an HTTPS endpoint on port \(Tailscale.httpsPort) of this Mac's tailnet name "
            + "(https://\(host):\(Tailscale.httpsPort)/) and forwards it to PhotoCull on "
            + "127.0.0.1:\(remote.port), with a real certificate. Port 443 is left alone. "
            + "The setting survives quitting PhotoCull and is reachable by every device signed in "
            + "to your tailnet; the pairing key still protects the photo API. "
            + "Remove it again with “\(Tailscale.removeCommandText)”."
    }

    // MARK: Actions

    private func isPresented(_ which: Confirmation) -> Binding<Bool> {
        Binding(get: { ui.value.confirmation == which },
                set: { shown in if !shown { ui.value.confirmation = .none } })
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
