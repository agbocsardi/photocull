import SwiftUI
import AppKit
import PhotoCullCore

/// The app window: a native sidebar + content + inspector arrangement
/// (NavigationSplitView), a unified toolbar for global actions, and a status bar.
struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            SessionsPane()
                // Mouse parity with the 1–4 focus keys: clicking a pane focuses it.
                .simultaneousGesture(TapGesture().onEnded { app.focusedPane = .sessions })
                .navigationSplitViewColumnWidth(min: Metric.sidebarMin,
                                                ideal: Metric.sidebarIdeal,
                                                max: 340)
        } detail: {
            VStack(spacing: 0) {
                ImagePane()
                    .simultaneousGesture(TapGesture().onEnded { app.focusedPane = .image })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Palette.separator)
                FilmstripPane()
                    .simultaneousGesture(TapGesture().onEnded { app.focusedPane = .filmstrip })
                    .frame(height: Metric.filmstripHeight)
                Divider().overlay(Palette.separator)
                StatusBar()
            }
            .background(Palette.window)
            .inspector(isPresented: $app.showInspector) {
                InfoPane()
                    .simultaneousGesture(TapGesture().onEnded { app.focusedPane = .info })
                    .inspectorColumnWidth(min: 220, ideal: Metric.inspectorWidth, max: 380)
            }
        }
        .navigationTitle(app.activeDate ?? "PhotoCull")
        .background(Palette.window)
        .toolbar { toolbarContent }
        .overlay(alignment: .bottom) { ToastView() }
        .background(CullWindowTag())
        .sheet(item: $app.modal) { modal in
            switch modal {
            case .help:      HelpSheet()
            case .ingest:    IngestSheet()
            case .finalize, .globalFinalize: FinalizeSheet()
            }
        }
        .onAppear {
            KeyMonitor.shared.handler = { [weak app] key in
                guard let app else { return false }
                return app.handle(key)
            }
            KeyMonitor.shared.start()
            // `--crop` opens crop mode so the overlay can be inspected in a snapshot.
            if CommandLine.arguments.contains("--crop") {
                app.enterCropMode()
                app.canvas.cropRect = CropRect(x: 0.14, y: 0.08, w: 0.62, h: 0.78)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Counter + current file + state, centred in the unified toolbar.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                if app.isDevLibrary {
                    DecisionBadge(text: "DEV LIBRARY", color: Palette.warning, compact: true)
                        .help("DEV library: \(LibraryMode.devRoot)\n"
                              + "Dev builds never touch your real photo library or real config.\n"
                              + "Install PhotoCull in Applications to use your real library.")
                }
                if app.activeDate != nil {
                    Text("[\(app.pairs.isEmpty ? 0 : app.index + 1)/\(app.pairs.count)]")
                        .font(Typo.number)
                        .foregroundStyle(Palette.secondary)
                    if let stem = app.currentStem {
                        Text("\(stem).JPG")
                            .font(Typo.mono)
                            .foregroundStyle(Palette.label)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220)
                    }
                    DecisionBadge(text: app.currentDecision.label,
                                  color: app.currentDecision.color,
                                  filled: app.currentDecision != .undecided)
                    if app.hasCrop { DecisionBadge(text: "CROP", color: Palette.crop) }
                    if app.currentPair?.hasRAW == true {
                        DecisionBadge(text: "+\(app.currentPair?.rawExt ?? "RAW")", color: Palette.raw)
                    }
                } else {
                    Text("No session selected")
                        .font(Typo.body)
                        .foregroundStyle(Palette.tertiary)
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.beginIngest()
            } label: {
                Label("Ingest", systemImage: "square.and.arrow.down")
            }
            .help("Ingest photos from an SD card (⌘⇧I)")

            Button {
                app.beginGlobalFinalize()
            } label: {
                Label("Finalize", systemImage: "checkmark.circle")
            }
            .disabled(app.visibleSessions.isEmpty)
            .help("Finalize selected sessions, or all visible sessions (⌘⇧F)")

            Button {
                app.toggleInspector()
            } label: {
                Label("Info", systemImage: "sidebar.right")
            }
            .help("Show or hide the info inspector (⌘I)")

            Menu {
                ForEach(AppAppearance.allCases) { choice in
                    Button {
                        app.appearance = choice
                    } label: {
                        if app.appearance == choice {
                            Label(choice.title, systemImage: "checkmark")
                        } else {
                            Text(choice.title)
                        }
                    }
                }
            } label: {
                Label("Appearance", systemImage: app.appearance.symbol)
            }
            .help("Appearance: \(app.appearance.title). Choose System, Light, or Dark")

            Button {
                app.modal = .help
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Keyboard shortcuts (?)")
        }
    }
}

// MARK: - Status bar

/// Thin bottom bar: key hints on the left, inbox location on the right.
/// Hints are plain buttons, with the same Keycap + label treatment.
struct StatusBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var loader: ImageLoader

    var body: some View {
        // One fixed-height row. Hints drop whole groups when the window is
        // narrow (every action stays in the photo bar / menus); the inbox
        // path yields first and truncates from the head.
        HStack(spacing: Metric.elementGap) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Metric.elementGap) { photoHints; otherHints }
                photoHints
                essentialHints
            }
            Spacer(minLength: Metric.elementGap)
            inbox.layoutPriority(-1)
        }
        .padding(.horizontal, Metric.paneInset)
        .frame(height: Metric.statusHeight)
        .background(Surface.chrome)
    }

    private var photoHints: some View {
        HStack(spacing: Metric.radiusBadge) {
            if app.cropMode {
                hint("a", "aspect", "Cycle the crop aspect ratio (a)") { app.cycleAspect() }
                hint("r", "reset", "Reset the crop region to the full frame (r)") { app.resetCrop() }
                hint("p", "preview", "Toggle the cropped preview (p)") { app.showCroppedPreview.toggle() }
                hint("t", "reset tilt", "Reset the tilt to 0° (t)") { app.resetTilt() }
            } else {
                hint("z", "keep", "Keep this photo and go to the next (z)") { app.mark(.keep) }
                hint("x", "reject", "Reject this photo and go to the next (x)") { app.mark(.reject) }
                hint("c", "crop", "Enter crop mode (c)") { app.enterCropMode() }
                hint("←", "prev", "Previous photo (← or k)") { app.nav(.prev) }
                hint("→", "next", "Next photo (→)") { app.nav(.next) }
                hint("K", "prev undec.", "Previous undecided photo (⇧K)") { app.nav(.prev, skipDecided: true) }
                hint("J", "next undec.", "Next undecided photo (⇧J)") { app.nav(.next, skipDecided: true) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(app.bulkOperation != nil)
    }

    private var otherHints: some View {
        HStack(spacing: Metric.radiusBadge) {
            if app.cropMode {
                hint("⏎", "apply", "Save the crop and leave crop mode (Enter)") { app.commitCrop() }
                hint("esc", "cancel", "Discard the crop changes (Esc)") { app.cancelCrop() }
            } else {
                hint("o", "preview", "Open the current photo in Preview (o)") { app.openInPreview() }
                hint("1-4", "pane", "Cycle keyboard focus between the four panes (1–4)") {
                    app.focusedPane = Pane(rawValue: (app.focusedPane.rawValue % 4) + 1) ?? .sessions
                }
                hint("tab", "filter", "Cycle the session filter (Tab in the sidebar)") { app.cycleFilter() }
                hint(":f", "finalize", "Finalize the current session (:f)") { app.beginFinalizeCurrent() }
                hint("?", "help", "Show the keyboard and mouse help (?)") { app.modal = .help }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(app.bulkOperation != nil)
    }

    /// The shortest set, for the narrowest windows.
    private var essentialHints: some View {
        HStack(spacing: Metric.radiusBadge) {
            if app.cropMode {
                hint("⏎", "apply", "Save the crop and leave crop mode (Enter)") { app.commitCrop() }
                hint("esc", "cancel", "Discard the crop changes (Esc)") { app.cancelCrop() }
            } else {
                hint("z", "keep", "Keep this photo and go to the next (z)") { app.mark(.keep) }
                hint("x", "reject", "Reject this photo and go to the next (x)") { app.mark(.reject) }
                hint("?", "help", "Show the keyboard and mouse help (?)") { app.modal = .help }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(app.bulkOperation != nil)
    }

    private var inbox: some View {
        HStack(spacing: Metric.elementGap) {
            if loader.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.55)
            }
            Text(app.cfg.paths.inbox.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Typo.mono)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
    private func hint(_ key: String, _ label: String, _ tip: String,
                      _ run: @escaping () -> Void) -> some View {
        StatusHintButton(key: key, label: label, tip: tip, run: run)
            .disabled(app.commandMode)
    }
}

/// One status-bar hint as a plain button: Keycap + label, hover background.
private struct StatusHintButton: View {
    let key: String
    let label: String
    let tip: String
    let run: () -> Void

    @StateObject private var hover = ViewState(false)

    var body: some View {
        Button(action: run) {
            HStack(spacing: Metric.radiusBadge) {
                Keycap(key: key)
                Text(label)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, Metric.radiusBadge / 2)
            .frame(height: Metric.statusHeight)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Metric.radiusBadge, style: .continuous)
                    .fill(hover.value ? Palette.hover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover.value = $0 }
        .help(tip)
        .accessibilityLabel(Text(tip))
    }
}

// MARK: - Toast

/// Lightweight confirmation that slides in and fades away.
struct ToastView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let toast = app.toast {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.keep)
                Text(toast)
                    .font(Typo.callout)
                    .foregroundStyle(Palette.label)
            }
            .padding(.horizontal, Metric.paneInset)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(Surface.floating)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(Palette.separator, lineWidth: 0.5))
            .shadowMedium()
            .padding(.bottom, Metric.floatingBottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
            .animation(Motion.normal, value: toast)
        }
    }
}

// MARK: - Command bar

/// Vim-style `:` command entry. Floats over the content, dismissed with Esc.
struct CommandBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Text(":").foregroundStyle(Palette.accent)
                Text(app.commandBuffer).foregroundStyle(Palette.label)
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 1.5, height: 14)
                    .opacity(0.9)
                Spacer(minLength: 40)
                Text("⏎ run · esc cancel")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.tertiary)
            }
            .font(Typo.body)
            .padding(.horizontal, Metric.paneInset)
            .frame(height: 32)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .fill(Surface.floating))
            .overlay(RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.5))
            .shadowMedium()
            .padding(.bottom, Metric.floatingBottom)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
