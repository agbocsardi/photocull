import SwiftUI
import AppKit
import PhotoCullCore

/// Sidebar: the list of inbox sessions. Uses native sidebar row styling —
/// subtle hover, quiet selection, no heavy borders.
struct SessionsPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(text: "Sessions", number: 1,
                          focused: app.focusedPane == .sessions,
                          trailing: { trailing })

            if app.visibleSessions.isEmpty {
                if app.sessions.isEmpty {
                    NoSessionsState()
                } else {
                    FilteredSessionsState(filterLabel: app.filter.label)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(app.visibleSessions) { row in
                                SessionRowView(row: row)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, Metric.elementGap)
                    }
                    .onChange(of: app.cursorDate) { _, new in
                        guard let new else { return }
                        withAnimation(Motion.fast) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .background(Surface.chrome)
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            if !app.selectedDates.isEmpty {
                Button {
                    withAnimation(Motion.fast) { app.clearSelection() }
                } label: {
                    Text("\(app.selectedDates.count) ✕")
                        .font(Typo.caption.weight(.semibold))
                        .foregroundStyle(Palette.warning)
                }
                .buttonStyle(.plain)
                .help("Clear selection (Esc)")
            }
            Button { app.cycleFilter() } label: {
                Text(app.filter.label)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.tertiary)
            }
            .buttonStyle(.plain)
            .help("Show next session filter (Tab when Sessions is focused)")
        }
    }
}

/// No sessions at all: the friendly first-run state — what to do first, and
/// where the inbox lives. Ingest and Settings are both one click away.
private struct NoSessionsState: View {
    @EnvironmentObject var app: AppState

    private var inboxPath: String {
        PCConfig.abbreviateHome(app.cfg.paths.inbox)
    }

    var body: some View {
        VStack(spacing: Metric.elementGap + 2) {
            Image(systemName: "photo.stack")
                .font(Typo.iconLarge)
                .foregroundStyle(Palette.quaternary)
            Text("No Sessions Yet")
                .font(Typo.title3)
                .foregroundStyle(Palette.secondary)
            Text("Ingest photos from an SD card — each capture date becomes a session you can cull.")
                .font(Typo.callout)
                .foregroundStyle(Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 12) {
                Button("Ingest Photos…") { app.beginIngest() }
                    .buttonStyle(ToolbarButtonStyle(prominent: true))
                    .help("Copy photos from an SD card into the inbox (⌘⇧I)")
                Button("Open Settings…") { openSettings() }
                    .buttonStyle(ToolbarButtonStyle())
                    .help("PhotoCull Settings (⌘,) — folders, file types, finalize defaults")
            }
            .padding(.top, 2)
            Text(inboxPath)
                .font(Typo.mono)
                .foregroundStyle(Palette.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metric.sectionGap)
    }

    /// Opens the Settings window. The settings UI is a real SwiftUI `Settings`
    /// scene (agent A); `showSettingsWindow:` is the action SwiftUI's own
    /// SettingsLink fires on macOS 14.
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// Sessions exist, but the filter hides them all: short message plus a
/// one-click way back to the full list.
private struct FilteredSessionsState: View {
    @EnvironmentObject var app: AppState
    let filterLabel: String

    var body: some View {
        VStack(spacing: Metric.elementGap + 2) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(Typo.iconLarge)
                .foregroundStyle(Palette.quaternary)
            Text("No Sessions Match")
                .font(Typo.title3)
                .foregroundStyle(Palette.secondary)
            Text("The \(filterLabel) filter hides every session right now.")
                .font(Typo.callout)
                .foregroundStyle(Palette.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Show All") { app.filter = .all }
                .buttonStyle(ToolbarButtonStyle())
                .help("Clear the session filter (Tab cycles it when Sessions is focused)")
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metric.sectionGap)
    }
}

/// One session row. Selection is quiet — a soft fill plus a bold date — as in
/// native sidebars, rather than a loud colour block.
private struct SessionRowView: View {
    @EnvironmentObject var app: AppState
    let row: SessionRow

    @StateObject private var hover = ViewState(false)

    private var isCursor: Bool { app.cursorDate == row.date }
    private var isActive: Bool { app.activeDate == row.date }
    private var isSelected: Bool { app.selectedDates.contains(row.date) }
    private var undecided: Int { row.total - row.keep - row.reject }

    var body: some View {
        HStack(spacing: 8) {
            // Progressive disclosure: the selection control only appears when the
            // row is hovered, selected, or the sidebar has keyboard focus.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Palette.accent : Palette.secondary.opacity(0.6))
                .opacity(showsSelectionControl ? 1 : 0)
                .onTapGesture { withAnimation(Motion.fast) { app.toggleSelection(row.date) } }
                .help(isSelected ? "Remove from multi-session selection" : "Select for multi-session finalize")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.date)
                        .font(isActive ? Typo.headline : Typo.body)
                        .foregroundStyle(isActive ? Palette.label : Palette.secondary)
                    Spacer(minLength: 0)
                    DecisionBadge(text: row.status.rawValue, color: row.status.color, compact: true)
                }

                HStack(spacing: 8) {
                    Text("\(undecided)/\(row.total)")
                        .font(Typo.number)
                        .foregroundStyle(Palette.secondary)
                        .help("Undecided / total photos")
                    if row.keep > 0 {
                        Text("\(row.keep)")
                            .font(Typo.number).foregroundStyle(Palette.keep)
                            .help("Kept photos")
                    }
                    if row.reject > 0 {
                        Text("\(row.reject)")
                            .font(Typo.number).foregroundStyle(Palette.reject)
                            .help("Rejected photos")
                    }
                    if row.cropped > 0 {
                        Image(systemName: "crop")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.crop)
                            .help("\(row.cropped) cropped")
                    }
                    Spacer(minLength: 0)
                }

                ProgressLine(value: row.progress,
                             tint: row.status == .complete ? Palette.keep : Palette.accent)
                    .opacity(row.status == .unstarted ? 0.4 : 1)
            }
        }
        .padding(.horizontal, Metric.paneInset - 4)
        .padding(.vertical, 4)
        .frame(minHeight: Metric.sidebarRow)
        .background(
            RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                .fill(fill)
        )
        .contentShape(Rectangle())
        .onHover { hover.value = $0 }
        .onTapGesture { handleRowClick() }
        .help("\(row.date) — click to open, ⌘-click to select for multi-finalize")
        .contextMenu {
            Button("Open") { app.open(date: row.date) }
            Button("Finalize…") { app.beginFinalize(date: row.date) }
            Divider()
            Button(isSelected ? "Deselect" : "Select for Multi-Finalize") {
                app.toggleSelection(row.date)
            }
        }
    }

    /// Mouse parity with the keyboard: a plain click opens the session (Enter),
    /// ⌘-click toggles it in the multi-finalize selection (Space) — the native
    /// macOS multi-select idiom.
    private func handleRowClick() {
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            withAnimation(Motion.fast) { app.toggleSelection(row.date) }
        } else if row.date == app.activeDate {
            app.cursorDate = row.date
        } else {
            app.open(date: row.date)
        }
    }

    private var showsSelectionControl: Bool {
        isSelected || hover.value || (isCursor && app.focusedPane == .sessions)
    }

    private var fill: Color {
        if isActive { return Palette.accent.opacity(0.16) }
        if isCursor { return Palette.quaternary.opacity(0.28) }
        if hover.value { return Palette.quaternary.opacity(0.16) }
        return .clear
    }
}
