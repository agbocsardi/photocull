import SwiftUI
import PhotoCullCore

// Modal presentation, native style: real sheets with a title, grouped content
// and a button bar using the standard cancel / default actions.

/// Shared sheet chrome: title, scrollable body, divider, button bar.
struct SheetShell<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 560
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Typo.title3)
                    .foregroundStyle(Palette.label)
                if let subtitle {
                    Text(subtitle)
                        .font(Typo.callout)
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider().overlay(Palette.separator)

            ScrollView {
                content()
                    .padding(Metric.sheetPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)

            Divider().overlay(Palette.separator)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                buttons()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: width)
        .background(Palette.window)
    }
}

/// A labelled group inside a sheet.
struct SheetGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Typo.sectionHeader)
                .tracking(0.4)
                .foregroundStyle(Palette.tertiary)
            content()
        }
        .padding(Metric.sheetGroupPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metric.radiusCard, style: .continuous)
                .fill(Palette.quaternary.opacity(0.16))
        )
        .hairlineBorder()
    }
}

// MARK: - Controls

/// Control reference, grouped by area. Each row names the action, its key,
/// and its mouse path, so the app can be driven either way — no key needs to
/// be memorised to use PhotoCull.
struct ControlsSheet: View {
    @EnvironmentObject var app: AppState

    private let culling: [(String, String, String)] = [
        ("Keep", "z", "✓ button in the photo bar"),
        ("Reject", "x", "✗ button in the photo bar"),
        ("Undo / redo", "⌘Z / ⇧⌘Z", "Edit menu"),
        ("Rotate", "–", "rotate buttons in the bar"),
        ("Open in Preview", "o", "Preview button in the bar"),
        ("Reveal in Finder", "f", "folder button in the bar"),
    ]
    private let navigation: [(String, String, String)] = [
        ("Next / prev photo", "j / k", "‹ › buttons in the photo bar"),
        ("Next / prev undecided", "J / K", "next-undecided button in the bar"),
        ("Jump to a photo", "← / →", "click a filmstrip thumbnail"),
        ("Focus a pane", "1 – 4", "click the pane"),
        ("Zoom in / out", "+ / −", "zoom buttons in the bar"),
        ("Fit to window", "0", "fit button in the bar"),
        ("Pan (when zoomed)", "drag", "drag the photo"),
    ]
    private let crop: [(String, String, String)] = [
        ("Move the region", "arrows", "drag inside the region"),
        ("Resize the region", "⇧ arrows", "drag a handle"),
        ("Cycle the aspect", "a", "aspect picker in the crop bar"),
        ("Reset the region", "r", "Reset button in the crop bar"),
        ("Cropped preview", "p", "preview toggle in the crop bar"),
        ("Tilt by 0.25°", ", / .", "tilt slider in the crop bar"),
        ("Reset the tilt", "t", "reset button in the crop bar"),
        ("Apply", "⏎", "Apply button in the crop bar"),
        ("Cancel", "esc", "Cancel button in the crop bar"),
    ]
    private let sessions: [(String, String, String)] = [
        ("Open a session", "⏎", "click it in the sidebar"),
        ("Select for finalize", "Space", "⌘-click a session"),
        ("Session menu", "–", "right-click a session"),
        ("Cycle the filter", "Tab", "filter chip in the sidebar"),
        ("Finalize session", ":f", "Finalize button in the toolbar"),
        ("Finalize selected", ":F", "Finalize button in the toolbar"),
        ("Ingest from a card", ":i", "Ingest button in the toolbar"),
        ("Show this sheet", "?", "Help menu in the toolbar"),
        ("Close a sheet", "esc", "Done / Cancel"),
    ]

    var body: some View {
        SheetShell(title: "Controls",
                   subtitle: "Every action with its key and its mouse path. Crop is non-destructive: originals are never modified.",
                   width: 860) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    column("Culling", culling)
                    column("Crop", crop)
                }
                VStack(alignment: .leading, spacing: 16) {
                    column("Navigation", navigation)
                    column("Sessions & files", sessions)
                }
            }
        } buttons: {
            Button("Getting Started…") { app.modal = .guide }
                .help("What PhotoCull is and the whole workflow")
            Button("Done") { app.modal = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func column(_ title: String, _ rows: [(String, String, String)]) -> some View {
        SheetGroup(title: title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    controlRow(row.0, row.1, row.2)
                }
            }
        }
    }

    /// "Keep — z — ✓ button in the photo bar": action left, keycap in the
    /// middle, mouse path right, so all three stay scannable in columns.
    private func controlRow(_ action: String, _ key: String, _ mouse: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(action)
                .font(Typo.callout)
                .foregroundStyle(Palette.label)
                .frame(width: 130, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Keycap(key: key)
                .frame(width: 74, alignment: .leading)
            Text(mouse)
                .font(Typo.callout)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Finalize

struct FinalizeSheet: View {
    @EnvironmentObject var app: AppState

    private var totals: (keep: Int, reject: Int, undecided: Int, photos: Int) {
        app.finalizeStats.reduce(into: (0, 0, 0, 0)) { acc, s in
            acc.0 += s.keep; acc.1 += s.reject; acc.2 += s.undecided; acc.3 += s.total
        }
    }

    var body: some View {
        let t = totals
        SheetShell(title: app.finalizeStats.count == 1
                     ? "Finalize \(app.finalizeStats.first?.date ?? "")"
                     : "Finalize \(app.finalizeStats.count) Sessions",
                   subtitle: "Rejects move to the Trash. Keepers move to the archive.",
                   width: 640) {
            VStack(alignment: .leading, spacing: 16) {
                SheetGroup(title: "Summary") {
                    VStack(spacing: 0) {
                        tableRow(bold: true, cells: ["Session", "Keep", "Reject", "Undecided", "Total"])
                        Divider().overlay(Palette.separator).padding(.vertical, 6)
                        ForEach(app.finalizeStats, id: \.date) { s in
                            tableRow(cells: [s.date, "\(s.keep)", "\(s.reject)",
                                             "\(s.undecided)", "\(s.total)"])
                        }
                        Divider().overlay(Palette.separator).padding(.vertical, 6)
                        tableRow(bold: true, cells: ["Total", "\(t.keep)", "\(t.reject)",
                                                     "\(t.undecided)", "\(t.photos)"])
                    }
                }

                if t.undecided > 0 {
                    Label("\(t.undecided) undecided photo\(t.undecided == 1 ? "" : "s") will be treated as keep.",
                          systemImage: "exclamationmark.triangle")
                        .font(Typo.callout)
                        .foregroundStyle(Palette.warning)
                }

                SheetGroup(title: "Copies to \(app.cfg.paths.dump.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") {
                    Picker("", selection: $app.cropExportMode) {
                        Text("Keep JPGs with the crop applied")
                            .help("Apply saved crops to exported copies; originals stay unchanged")
                            .tag(CropExportMode.applyCrop)
                        Text("Keep the original JPGs")
                            .help("Export full-frame JPG copies without applying saved crops")
                            .tag(CropExportMode.original)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .font(Typo.callout)
                    .help("Crop settings affect only exported JPG copies, not the originals")
                }
            }
        } buttons: {
            Button("Cancel") { app.modal = nil }
                .keyboardShortcut(.cancelAction)
            Button("Finalize") { app.confirmFinalize() }
                .keyboardShortcut(.defaultAction)
                .help("Move rejects to Trash and keepers to the archive; export keeper JPGs")
        }
    }

    private func tableRow(bold: Bool = false, cells: [String]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                Text(cell)
                    .font(bold ? Typo.numberBold : Typo.number)
                    .foregroundStyle(color(for: i))
                    .frame(width: i == 0 ? 170 : 78, alignment: i == 0 ? .leading : .trailing)
            }
            Spacer(minLength: 0)
        }
    }

    private func color(for column: Int) -> Color {
        switch column {
        case 1: return Palette.keep
        case 2: return Palette.reject
        case 3: return Palette.secondary
        default: return Palette.label
        }
    }
}

// MARK: - Ingest

struct IngestSheet: View {
    @EnvironmentObject var app: AppState
    @FocusState private var pathFocused: Bool

    var body: some View {
        SheetShell(title: "Ingest Photos",
                   subtitle: "Photos are copied into the inbox, grouped by capture date. The card is never modified.",
                   width: 600) {
            VStack(alignment: .leading, spacing: 16) {
                SheetGroup(title: "Source") {
                    VStack(alignment: .leading, spacing: 8) {
                        if app.detectedCards.isEmpty {
                            Label("No SD card detected under /Volumes/ with a DCIM folder.",
                                  systemImage: "sdcard")
                                .font(Typo.callout)
                                .foregroundStyle(Palette.warning)
                        } else {
                            ForEach(app.detectedCards, id: \.path) { url in
                                Button {
                                    app.ingestSource = url.path
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: app.ingestSource == url.path
                                              ? "largecircle.fill.circle" : "circle")
                                            .font(.system(size: 12))
                                            .foregroundStyle(app.ingestSource == url.path
                                                             ? Palette.accent : Palette.quaternary)
                                        Text(url.path)
                                            .font(Typo.mono)
                                            .foregroundStyle(Palette.label)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Use \(url.lastPathComponent) as the photo source")
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("/Volumes/SDCARD/DCIM", text: $app.ingestSource)
                                .textFieldStyle(.roundedBorder)
                                .font(Typo.mono)
                                .focused($pathFocused)
                                .disabled(app.ingestProgress.running)
                                .help("Folder to copy photos from; the source is not changed")
                            Button("Choose…") { chooseFolder() }
                                .disabled(app.ingestProgress.running)
                                .help("Choose a folder containing your photos")
                        }
                    }
                }

                if app.ingestProgress.running || app.ingestProgress.done {
                    SheetGroup(title: "Progress") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(app.ingestProgress.copied),
                                         total: Double(max(1, app.ingestProgress.total)))
                                .tint(Palette.keep)
                            HStack {
                                Text("\(app.ingestProgress.copied) of \(app.ingestProgress.total) copied")
                                    .font(Typo.number)
                                    .foregroundStyle(Palette.secondary)
                                Spacer(minLength: 8)
                                Text(app.ingestProgress.current)
                                    .font(Typo.mono)
                                    .foregroundStyle(Palette.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if let err = app.ingestProgress.error {
                                Label(err, systemImage: "exclamationmark.triangle")
                                    .font(Typo.callout)
                                    .foregroundStyle(Palette.reject)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        } buttons: {
            Button("Close") { app.modal = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(app.ingestProgress.running)
            Button("Start Ingest") { app.startIngest() }
                .keyboardShortcut(.defaultAction)
                .disabled(app.ingestProgress.running || app.ingestSource.isEmpty)
                .help("Copy photos into the inbox by capture date; the source is not changed")
        }
        .onAppear { pathFocused = false }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Source"
        if panel.runModal() == .OK, let url = panel.url { app.ingestSource = url.path }
    }
}
