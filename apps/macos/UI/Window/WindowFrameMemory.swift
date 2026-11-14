import AppKit

/// Remembers where a window was across launches, as `setFrameAutosaveName` does, but writes it once the window has
/// come to rest instead of on every step of a drag. Each write to `UserDefaults` makes SwiftUI re-run every view that
/// reads `@AppStorage`; with AppKit's autosave the whole main window was laid out again for each pixel it moved, the
/// drag fell behind the pointer and, crossing onto another screen, the window jumped away from it.
///
/// It uses AppKit's own key (`NSWindow Frame <name>`), so a frame saved by the autosave before is found again.
@MainActor
final class WindowFrameMemory {
    private let key: String
    private weak var window: NSWindow?
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow, name: String) {
        key = "NSWindow Frame \(name)"
        self.window = window
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveSoon() }
            })
        }
        for (name, object) in [(NSWindow.willCloseNotification, window as AnyObject), (NSApplication.willTerminateNotification, nil)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
    }

    deinit {
        pending?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Puts the window where it was last; false when there is nothing saved.
    @discardableResult
    func restore() -> Bool {
        guard let window, let saved = UserDefaults.standard.string(forKey: key) else { return false }
        window.setFrame(from: saved)
        return true
    }

    private func saveSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        pending?.cancel()
        pending = nil
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frameDescriptor
        guard UserDefaults.standard.string(forKey: key) != frame else { return }
        UserDefaults.standard.set(frame, forKey: key)
    }
}
