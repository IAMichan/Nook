import AppKit
import SwiftUI

/// One global shortcut in Settings: click it, press the new keys. Esc cancels, ⌫ turns it off.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @EnvironmentObject private var app: AppModel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var note = ""

    private var current: Shortcut? { ShortcutSet.load().shortcut(for: action) }

    var body: some View {
        LabeledContent(Self.title(action)) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    Button { recording ? stop() : start() } label: {
                        if recording {
                            Text(tr("shortcut.record")).foregroundStyle(NookTheme.textSecondary)
                        } else if let current {
                            Keycap(label: current.display)
                        } else {
                            Text(tr("shortcut.off")).foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    if current != action.defaultShortcut, !recording {
                        Button { app.setShortcut(action.defaultShortcut, for: action); note = "" } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help(tr("shortcut.reset"))
                    }
                }
                if !note.isEmpty { Text(note).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary) }
            }
        }
        .onDisappear { stop() }
    }

    static func title(_ action: ShortcutAction) -> String {
        switch action {
        case .talk: return tr("settings.overview.talkNook")
        case .ask: return tr("settings.overview.askTyping")
        case .lookAtScreen: return tr("settings.overview.lookScreen")
        case .screenPart: return tr("shortcut.screenPart")
        case .recordCall: return tr("shortcut.recordCall")
        }
    }

    private func start() {
        note = ""
        recording = true
        // Nook's own keys are paused while you press the new ones, so the old shortcut does not fire.
        app.hotKeys = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { app.reloadHotKeys() }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let code = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if code == 0x35, flags.isEmpty { stop(); return }                          // Esc: keep what it was
        if code == 0x33 || code == 0x75, flags.isEmpty {                           // ⌫: off
            stop()
            app.setShortcut(nil, for: action)
            return
        }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= Shortcut.command }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.control) { modifiers |= Shortcut.control }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        let shortcut = Shortcut(keyCode: code, modifiers: modifiers)
        guard shortcut.isValid else { note = tr("shortcut.invalid"); return }
        stop()
        if let displaced = app.setShortcut(shortcut, for: action) {
            note = tr("shortcut.moved", Self.title(displaced))
        }
    }
}
