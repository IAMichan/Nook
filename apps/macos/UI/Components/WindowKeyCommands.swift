import AppKit
import SwiftUI

extension View {
    /// The keys that work anywhere in a panel's window (the notch, the main window): F6 / ⇧F6 move the keyboard between
    /// the window's parts (`FocusAreas`), and with a terminal focused ⌘W closes it and ⌘D / ⇧⌘D split it to the right or
    /// down. Window-wide fallbacks: a view that offers the same command goes first.
    func windowKeyCommands() -> some View {
        keyCommands([
            "focus.next": { WindowKeys.cycleFocus(1) },
            "focus.previous": { WindowKeys.cycleFocus(-1) },
            "tab.close": { WindowKeys.closeTerminal() },
            "terminal.splitRight": { WindowKeys.splitTerminal(.sideBySide) },
            "terminal.splitDown": { WindowKeys.splitTerminal(.stacked) },
        ], priority: -1)
    }
}

@MainActor
enum WindowKeys {
    static func cycleFocus(_ step: Int) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return FocusAreas.shared.cycle(step, in: window)
    }

    /// The terminal session whose view has the keyboard.
    private static func focusedTerminal() -> TerminalSession? {
        guard let view = KeyCommandCenter.focusedTerminal(NSApp.keyWindow?.firstResponder) else { return nil }
        return TerminalStore.shared.sessions.first { $0.view === view }
    }

    /// ⌘W in a terminal: ends that terminal (the next one of its split takes the keyboard) instead of closing the window.
    static func closeTerminal() -> Bool {
        guard let session = focusedTerminal() else { return false }
        let store = TerminalStore.shared
        store.close(session.id)
        if let next = store.selected.flatMap({ id in store.sessions.first { $0.id == id } }) {
            DispatchQueue.main.async { next.view.window?.makeFirstResponder(next.view) }
        }
        return true
    }

    /// ⌘D / ⇧⌘D in a terminal: a new terminal in the same folder beside or under it, with the keyboard. A full split
    /// (`TerminalStore.maxPerGroup`) lets the key go.
    static func splitTerminal(_ split: TerminalSplit) -> Bool {
        guard let session = focusedTerminal(), let added = TerminalStore.shared.split(session.id, split) else { return false }
        // Once the new pane is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { added.view.window?.makeFirstResponder(added.view) }
        return true
    }
}
