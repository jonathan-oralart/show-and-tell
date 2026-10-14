import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global hotkey: capture the front window, or dismiss the open capture.
    static let capture = Self("capture", default: .init(.two, modifiers: [.command, .shift]))
    /// Global hotkey: start recording the screen, or stop and pick frames.
    static let record = Self("record", default: .init(.r, modifiers: [.control, .option, .command]))
    /// Global hotkey: open the last 30 seconds of the screen to pick frames, when that's kept.
    static let replay = Self("replay", default: .init(.l, modifiers: [.control, .option, .command]))

    // While annotating. Changeable in Settings; only active while the overlay is open.
    static let send = Self("send", default: .init(.return, modifiers: .command))
    static let copy = Self("copy", default: .init(.c, modifiers: .command))
    static let discard = Self("discard", default: .init(.delete, modifiers: .command))

    /// The shortcut as symbols, like "⌘↩", or nil when it's been cleared in Settings.
    var symbols: String? {
        KeyboardShortcuts.getShortcut(for: self)?.description
    }

    /// Recording a shortcut takes it from whichever other action had it, so one key never does two things.
    func takeShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let shortcut else { return }
        for name in [Self.capture, .record, .replay, .send, .copy, .discard] where name != self && KeyboardShortcuts.getShortcut(for: name) == shortcut {
            KeyboardShortcuts.setShortcut(nil, for: name)
        }
    }
}
