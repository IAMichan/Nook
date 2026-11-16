import AppKit
import Carbon.HIToolbox

/// Holds ⌘Q while "Hold ⌘Q to quit" is on (Settings › General): a key monitor that takes ⌘Q before the menu's key
/// equivalent sees it, feeds `QuitHold`, shows its hint as a toast where you are, and quits once the hold says so.
///
/// It only ever sees key events sent to Nook. Quit in the menu bar menu or a click on Quit in the app menu, and macOS
/// quitting Nook (logout, restart, an update's relaunch), go to `applicationShouldTerminate` directly and are never held
/// up. With the setting off (the default) ⌘Q passes untouched.
@MainActor
final class QuitHoldMonitor {
    static let shared = QuitHoldMonitor()

    /// Whether ⌘Q has to be held (Settings › General).
    static let enabledKey = "nook.quit.holdCommandQ"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var monitor: Any?
    private var hold = QuitHold()
    private var check: DispatchWorkItem?
    /// The hint toast on screen, to take it away when the hold ends.
    private var hintTitle: String?
    /// Set by `AppDelegate` while a quit is under way (agents stopping): ⌘Q then needs no hint.
    var quitting = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            // Local monitors are called on the main thread; NSEvent is not Sendable, so it crosses as unchecked.
            nonisolated(unsafe) let event = event
            let passOn = MainActor.assumeIsolated { self.map { $0.handle(event) != nil } ?? true }
            return passOn ? event : nil
        }
    }

    /// Returns the event to pass on, or nil when it was ⌘Q and the hold took it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Off, or nothing that ⌘Q would trigger (no menu bar while Nook only shows in the notch): leave every key alone.
        guard Self.isEnabled, NSApp.mainMenu != nil else {
            if !hold.isIdle { apply(hold.handle(.otherKey, at: Date())) }
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isQ = event.type != .flagsChanged && event.keyCode == UInt16(kVK_ANSI_Q)
        switch event.type {
        case .keyDown where isQ && flags == .command:
            if quitting { return nil }
            apply(hold.handle(event.isARepeat ? .repeated : .pressed, at: Date()))
            return nil
        case .keyDown:
            if !hold.isIdle { apply(hold.handle(.otherKey, at: Date())) }
            return event
        case .keyUp where isQ:
            guard !hold.isIdle else { return event }
            apply(hold.handle(.released, at: Date()))
            return nil
        case .flagsChanged where !flags.contains(.command):
            if !hold.isIdle { apply(hold.handle(.released, at: Date())) }
            return event
        default:
            return event
        }
    }

    private func apply(_ output: QuitHold.Output) {
        if let hint = output.hint { show(hint) }
        if let at = output.checkAt { schedule(at) }
        if output.quit {
            check?.cancel()
            check = nil
            NSApp.terminate(nil)
        }
    }

    /// Asks `QuitHold` again at `date`, with whether Q is still down. Reading the key's state posts nothing and needs no
    /// permission.
    private func schedule(_ date: Date) {
        check?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.check = nil
                let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_Q))
                self.apply(self.hold.handle(.check(keyDown: down), at: Date()))
            }
        }
        check = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, date.timeIntervalSinceNow), execute: work)
    }

    /// The hint as a toast on the surface you are in: a calm line that goes by itself shortly after the key does.
    private func show(_ hint: QuitHold.Hint) {
        let center = ToastCenter.shared
        if let shown = hintTitle, let toast = center.toasts.first(where: { $0.title == shown }) {
            // The release hint replaces the hold hint; the hold hint stays a moment after a quick tap, so it can be read.
            if hint != .hidden { center.dismiss(toast.id) }
        }
        switch hint {
        case .hold:
            hintTitle = tr("quit.hold.hint")
            center.show(tr("quit.hold.hint"), kind: .info, duration: 1.6)
        case .release:
            hintTitle = tr("quit.hold.release")
            center.show(tr("quit.hold.release"), kind: .info, duration: 2)
        case .hidden:
            hintTitle = nil
        }
    }
}
