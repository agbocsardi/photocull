import SwiftUI
import AppKit
import PhotoCullCore

// SettingsView.swift — the real macOS settings window (Settings scene, ⌘,).
//
// Edits land in a draft; the window shows validate() problems inline, and
// Apply saves through AppState.updateConfig, which creates missing folders,
// writes the config file and reloads the library. In fixture mode the draft is
// read-only; updateConfig also refuses fixture mode and running bulk work.

/// Draft state for the settings window: the three paths, the two editable
/// extension lists (kept as text until parsed) and the finalize options.
@MainActor
private final class SettingsDraft: ObservableObject {
    @Published var inbox: String
    @Published var archive: String
    @Published var exports: String
    @Published var rawText: String
    @Published var jpgText: String
    @Published var exportJPGs: Bool
    @Published var cropExport: String

    init(cfg: PCConfig) {
        inbox = cfg.paths.inbox
        archive = cfg.paths.archive
        exports = cfg.paths.dump
        rawText = cfg.files.rawExtensions.joined(separator: ", ")
        jpgText = cfg.files.jpgExtensions.joined(separator: ", ")
        exportJPGs = cfg.finalize.exportJPGs
        cropExport = cfg.finalize.cropExport
    }

    /// Reset every field from a configuration (Revert / first show).
    func adopt(_ cfg: PCConfig) {
        inbox = cfg.paths.inbox
        archive = cfg.paths.archive
        exports = cfg.paths.dump
        rawText = cfg.files.rawExtensions.joined(separator: ", ")
        jpgText = cfg.files.jpgExtensions.joined(separator: ", ")
        exportJPGs = cfg.finalize.exportJPGs
        cropExport = cfg.finalize.cropExport
    }

    /// The configuration the draft currently describes.
    var config: PCConfig {
        PCConfig(paths: PathsConfig(inbox: inbox.trimmingCharacters(in: .whitespacesAndNewlines),
                                    archive: archive.trimmingCharacters(in: .whitespacesAndNewlines),
                                    dump: exports.trimmingCharacters(in: .whitespacesAndNewlines)),
                 files: FilesConfig(rawExtensions: Self.parseExtensions(rawText),
                                    jpgExtensions: Self.parseExtensions(jpgText)),
                 finalize: FinalizeConfig(exportJPGs: exportJPGs, cropExport: cropExport))
    }

    /// Comma-separated text to an uppercase, dot-free, de-duplicated list.
    static func parseExtensions(_ text: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let ext = piece.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .trimmingCharacters(in: .whitespaces).uppercased()
            if !ext.isEmpty, !seen.contains(ext) { seen.insert(ext); out.append(ext) }
        }
        return out
    }
}

/// Thin root: feeds the app's current config into the settings tabs.
struct SettingsRoot: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SettingsView(cfg: app.cfg)
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var draft: SettingsDraft

    init(cfg: PCConfig) {
        _draft = StateObject(wrappedValue: SettingsDraft(cfg: cfg))
    }

    private var changed: Bool { draft.config != app.cfg }
    private var readOnly: Bool { app.fixtureMode }

    private var applyDisabled: Bool {
        readOnly || app.bulkOperation != nil || !changed || !draft.config.validate().isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                FoldersTab(draft: draft, readOnly: readOnly)
                    .tabItem { Label("Folders", systemImage: "folder") }
                FilesTab(draft: draft, readOnly: readOnly)
                    .tabItem { Label("Files", systemImage: "photo") }
                FinalizeTab(draft: draft, readOnly: readOnly)
                    .tabItem { Label("Finalize", systemImage: "checkmark.circle") }
                GeneralTab(draft: draft, readOnly: readOnly)
                    .tabItem { Label("General", systemImage: "gearshape") }
            }
            Divider().overlay(Palette.separator)
            footer
        }
        .frame(width: 560, height: 470)
        .background(Palette.window)
    }

    /// Problems from the draft, then the shared action row.
    private var footer: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
            ForEach(draft.config.validate(), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Typo.caption)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Metric.elementGap) {
                if readOnly {
                    Text("Read-only: disposable fixture mode.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer(minLength: 0)
                Button("Revert") { draft.adopt(app.cfg) }
                    .disabled(!changed)
                    .help("Discard every change in this window")
                Button("Apply") {
                    if app.updateConfig(draft.config) { draft.adopt(app.cfg) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(applyDisabled)
                .help("Save the config, create missing folders and reload the library")
            }
        }
        .padding(Metric.sheetPadding)
    }
}

// MARK: - Folders

private struct FoldersTab: View {
    @ObservedObject var draft: SettingsDraft
    var readOnly: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionGap) {
                Label("Changing a folder only repoints PhotoCull; nothing on disk is moved or renamed.",
                      systemImage: "info.circle")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FolderRow(title: "Inbox",
                          explanation: "Sessions are read from dated folders inside this one.",
                          path: $draft.inbox, readOnly: readOnly)
                FolderRow(title: "Archive",
                          explanation: "Keepers move here when a session is finalized.",
                          path: $draft.archive, readOnly: readOnly)
                FolderRow(title: "Exports",
                          explanation: "Finalize drops keeper JPG copies into a dated folder inside this one.",
                          path: $draft.exports, readOnly: readOnly)
            }
            .padding(Metric.sheetPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FolderRow: View {
    let title: String
    let explanation: String
    @Binding var path: String
    var readOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
            HStack(spacing: Metric.elementGap) {
                Text(title).font(Typo.headline).foregroundStyle(Palette.label)
                Spacer(minLength: 0)
                Button("Choose…") { choose() }
                    .disabled(readOnly)
                    .help("Pick a folder; existing files stay exactly where they are")
                Button("Reveal") { reveal() }
                    .disabled(readOnly)
                    .help("Show the \(title.lowercased()) folder in Finder")
            }
            Text(explanation)
                .font(Typo.caption)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(PCConfig.abbreviateHome(path))
                .font(Typo.mono)
                .foregroundStyle(Palette.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PCConfig.expandHome(path))])
    }
}

// MARK: - Files

private struct FilesTab: View {
    @ObservedObject var draft: SettingsDraft
    var readOnly: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionGap) {
                Label("A JPG and a RAW with the same filename stem form one pair: rejecting the JPG trashes the RAW too, and finalize moves them together. Extensions match without dots, case ignored.",
                      systemImage: "link")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ExtensionField(title: "RAW extensions",
                               help: "Camera RAW formats to pair by filename stem",
                               placeholder: "RAF, RW2, …", text: $draft.rawText, readOnly: readOnly)
                ExtensionField(title: "JPG extensions",
                               help: "Formats PhotoCull displays and culls",
                               placeholder: "JPG, JPEG", text: $draft.jpgText, readOnly: readOnly)
            }
            .padding(Metric.sheetPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ExtensionField: View {
    let title: String
    let help: String
    let placeholder: String
    @Binding var text: String
    var readOnly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
            Text(title).font(Typo.headline).foregroundStyle(Palette.label)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(Typo.mono)
                .disabled(readOnly)
                .help(help)
            Text("Comma-separated; normalised to uppercase without dots.")
                .font(Typo.caption)
                .foregroundStyle(Palette.tertiary)
        }
    }
}

// MARK: - Finalize

private struct FinalizeTab: View {
    @ObservedObject var draft: SettingsDraft
    var readOnly: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionGap) {
                Toggle("Export keeper JPG copies to the exports folder", isOn: $draft.exportJPGs)
                    .font(Typo.body)
                    .disabled(readOnly)
                    .help("When off, finalize only archives keepers and trashes rejects; no copies are written")
                VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
                    Text("Default crop export").font(Typo.headline).foregroundStyle(Palette.label)
                    Picker("", selection: $draft.cropExport) {
                        Text("Cropped copies — apply saved crops")
                            .tag(FinalizeConfig.cropExportCrop)
                        Text("Originals — full frame")
                            .tag(FinalizeConfig.cropExportOriginal)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .font(Typo.callout)
                    .disabled(readOnly)
                    Text("Each finalize sheet can override this choice. It affects only exported copies, never the originals.")
                        .font(Typo.caption)
                        .foregroundStyle(Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Metric.sheetPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var draft: SettingsDraft
    var readOnly: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metric.sectionGap) {
                VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
                    Text("Appearance").font(Typo.headline).foregroundStyle(Palette.label)
                    Picker("", selection: $app.appearance) {
                        ForEach(AppAppearance.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .help("Overrides PhotoCull only; the computer's appearance is untouched")
                }
                VStack(alignment: .leading, spacing: Metric.elementGap / 2) {
                    Text("Config file").font(Typo.headline).foregroundStyle(Palette.label)
                    Text(PCConfig.configPath)
                        .font(Typo.mono)
                        .foregroundStyle(Palette.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Reveal Config File") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PCConfig.configPath)])
                    }
                    .disabled(readOnly)
                    .help("Show config.toml selected in Finder")
                }
                Button("Restore Defaults") { draft.adopt(PCConfig.defaultConfig()) }
                    .disabled(readOnly)
                    .help("Reset every tab to the built-in defaults; nothing is written until Apply")
            }
            .padding(Metric.sheetPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
