import AppKit
import Combine

/// Whether ⌘ alone has been held for a moment (200 ms), so a list can show which ⌘-number opens which row. The monitor
/// runs only between `start()` and `stop()` (while the Agents list is on screen) and publishes only when the answer
/// changes; a ⌘-shortcut typed before the moment is up never shows the hints.
@MainActor
final class CommandHoldMonitor: ObservableObject {
    @Published private(set) var held = false
    private var monitor: Any?
    private var pending: DispatchWorkItem?
    static let delay: TimeInterval = 0.2
    private static let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cancel()
        set(false)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            if event.modifierFlags.intersection(Self.modifiers) == .command {
                guard pending == nil, !held else { return }
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pending = nil
                        if NSEvent.modifierFlags.intersection(Self.modifiers) == .command { self.set(true) }
                    }
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
            } else {
                cancel()
                set(false)
            }
        case .keyDown:
            // A shortcut typed straight away: no hints for it.
            cancel()
        default:
            break
        }
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func set(_ value: Bool) {
        if held != value { held = value }
    }
}
