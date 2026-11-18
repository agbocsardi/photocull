import Foundation
import PhotoCullCore

/// The single preference store for the app. In DEV mode preferences go to a
/// dedicated suite, so development runs never touch the installed app's
/// (or any other app's) defaults; the installed app uses the standard domain.
///
/// Everything that persists a preference (appearance, guide-seen flag, …)
/// must route through here, never `UserDefaults.standard` directly.
enum AppDefaults {
    static let store: UserDefaults = LibraryMode.current == .dev
        ? UserDefaults(suiteName: "local.photocull.swift.dev") ?? .standard
        : .standard
}
