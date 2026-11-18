import SwiftUI
import PhotoCullCore

// GuideSheet.swift — the Getting Started guide. Shown once on first launch
// (UserDefaults `PhotoCull.hasSeenGuide`) and reachable any time from the
// toolbar Help menu or Help ▸ PhotoCull Getting Started. Its job: a newcomer
// understands what PhotoCull is for and can drive the whole workflow without
// knowing a single key.

/// One workflow step: numeral, SF Symbol, title, one- or two-line explanation.
private struct GuideStep: View {
    let number: String
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(Typo.iconMedium)
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                        .fill(Palette.accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.radiusButton, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .help("Step \(number): \(title)")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number) · \(title)")
                    .font(Typo.headline)
                    .foregroundStyle(Palette.label)
                Text(text)
                    .font(Typo.callout)
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One folder row inside "Where files live": label left, mono path right.
private struct GuideLocation: View {
    let symbol: String
    let label: String
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(Typo.iconSmall)
                .foregroundStyle(Palette.accent)
            Text(label)
                .font(Typo.callout)
                .foregroundStyle(Palette.label)
            Spacer(minLength: 8)
            Text(path)
                .font(Typo.mono)
                .foregroundStyle(Palette.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }
}

/// One safety promise: shield icon plus a single line.
private struct GuidePromise: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(Typo.callout)
                .foregroundStyle(Palette.label)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(Typo.iconSmall)
                .foregroundStyle(Palette.keep)
        }
    }
}

struct GuideSheet: View {
    @EnvironmentObject var app: AppState

    /// `~/`-abbreviated paths, matching the status bar's presentation.
    private func display(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        SheetShell(title: "Getting Started",
                   subtitle: "PhotoCull is a fast, keyboard-first culler for RAW+JPG shoots. Four steps, no database, nothing destructive.",
                   width: 680) {
            VStack(alignment: .leading, spacing: 16) {
                SheetGroup(title: "The workflow") {
                    VStack(alignment: .leading, spacing: 12) {
                        GuideStep(number: "1", symbol: "square.and.arrow.down", title: "Ingest",
                                  text: "Copy a shoot in from the SD card (or any folder). Photos are grouped into sessions by capture date. Files are only ever copied — the card is never touched.")
                        GuideStep(number: "2", symbol: "eye", title: "Cull",
                                  text: "Step through the JPGs and mark each one keep or reject. You always cull the JPG; its paired RAW (same filename) follows wherever the JPG goes.")
                        GuideStep(number: "3", symbol: "crop", title: "Crop (optional)",
                                  text: "Straighten and crop keepers. The original files are never modified — the crop is stored in the session and applied only to exported copies.")
                        GuideStep(number: "4", symbol: "shippingbox", title: "Finalize",
                                  text: "Rejects move to the macOS Trash with their RAWs, keepers move to the archive, and each keeper JPG is copied into the exports folder, ready for Apple Photos.")
                    }
                }

                SheetGroup(title: "Where files live") {
                    VStack(alignment: .leading, spacing: 8) {
                        GuideLocation(symbol: "tray.full", label: "Inbox — new sessions land here",
                                      path: display(app.cfg.paths.inbox))
                        GuideLocation(symbol: "archivebox", label: "Archive — finalized keepers (JPG + RAW)",
                                      path: display(app.cfg.paths.archive))
                        GuideLocation(symbol: "paperplane", label: "Exports — keeper JPGs for Apple Photos",
                                      path: display(app.cfg.paths.dump))
                        SettingsLink {
                            Label("Change these in Settings…", systemImage: "gearshape")
                                .font(Typo.callout)
                        }
                        .help("PhotoCull Settings (⌘,)")
                    }
                }

                SheetGroup(title: "Safety promises") {
                    VStack(alignment: .leading, spacing: 8) {
                        GuidePromise(symbol: "sdcard",
                                     text: "The card is never modified — ingest copies, it never moves or deletes.")
                        GuidePromise(symbol: "checkmark.shield",
                                     text: "Originals are never modified — crop, tilt and rotation live in the session's .photocull.json, not inside your photos.")
                        GuidePromise(symbol: "trash",
                                     text: "Nothing is deleted outright — rejected photos move to the Trash, where you can get them back.")
                    }
                }

                Text("Photos you leave undecided are treated as keep when you finalize. Every decision is stored next to the photos, in the session folder's .photocull.json.")
                    .font(Typo.callout)
                    .foregroundStyle(Palette.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } buttons: {
            Button("Show Controls") { app.modal = .help }
                .help("Every action with its key and its mouse path (?)")
            Button("Done") { app.modal = nil }
                .keyboardShortcut(.defaultAction)
        }
    }
}
