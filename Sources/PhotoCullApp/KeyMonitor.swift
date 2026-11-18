import AppKit

/// A single key press, normalised for the cull keymap.
struct KeyEvent {
    enum Arrow { case up, down, left, right }
    var chars: String        // lowercased printable characters, "" for specials
    var shift: Bool
    var command: Bool
    var option: Bool
    var control: Bool
    var arrow: Arrow?
    var isEscape: Bool
    var isReturn: Bool
    var isTab: Bool
    var isSpace: Bool
    var isDelete: Bool

    /// The key as written in the help table, e.g. "j", "J", "Enter", "→".
    var displayKey: String {
        if isEscape { return "Esc" }
        if isReturn { return "Enter" }
        if isTab { return "Tab" }
        if isSpace { return "Space" }
        if isDelete { return "⌫" }
        switch arrow {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case nil: break
        }
        return shift ? chars.uppercased() : chars
    }
}

/// Installs a local NSEvent monitor and routes key presses to a handler.
/// The handler returns `true` when the event was consumed.
@MainActor
final class KeyMonitor {
    static let shared = KeyMonitor()

    var handler: ((KeyEvent) -> Bool)?
    /// When true, all keys are passed straight through (e.g. a sheet is up).
    var suspended = false
    /// The main cull window. Keys typed in any other window (the Settings
    /// scene, panels) belong to that window's controls, not the cull keymap.
    /// Sheets are child windows of it, so modal keys keep working. Latched
    /// once at launch; if nil, routing falls back to the permissive behaviour.
    weak var cullWindow: NSWindow?

    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.route(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func route(_ event: NSEvent) -> Bool {
        guard !suspended, let handler else { return false }

        // The cull keymap belongs to the cull window (and its sheets) only.
        // The Settings scene is a separate key window: keys pressed there —
        // whether in a text field or any other focused control — must reach
        // that window, never the cull map.
        if let cull = cullWindow, event.window !== cull, event.window?.parent !== cull {
            return false
        }

        // Never steal keys from a focused text field / editor.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let raw = event.charactersIgnoringModifiers ?? ""
        let lower = raw.lowercased()

        // Leave system shortcuts (⌘…) alone — except undo/redo.
        if event.modifierFlags.contains(.command), lower != "z" { return false }

        var arrow: KeyEvent.Arrow?
        switch event.keyCode {
        case 123: arrow = .left
        case 124: arrow = .right
        case 125: arrow = .down
        case 126: arrow = .up
        default: break
        }

        let key = KeyEvent(
            chars: lower,
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control),
            arrow: arrow,
            isEscape: event.keyCode == 53,
            isReturn: event.keyCode == 36 || event.keyCode == 76,
            isTab: event.keyCode == 48,
            isSpace: event.keyCode == 49,
            isDelete: event.keyCode == 51 || event.keyCode == 117
        )
        return handler(key)
    }
}
