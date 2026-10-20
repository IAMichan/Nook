import AppKit
import ApplicationServices

/// The observer's callback. At file level: a C function pointer may not carry the observer's main-actor isolation. The
/// observer's source is on the main run loop, so it is entered on the main thread.
private let fieldObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let observer = Unmanaged<AutocompleteFieldObserver>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { observer.received(name) }
}

/// Tells autocomplete the moment the front app changes the text of a field or moves the focus, through the Accessibility API's
/// notifications. After a key, the field is then read again as soon as the app has taken it in, instead of on the next tick of
/// a timer. Apps that send no notifications still work: the timer stays as the fallback.
@MainActor
final class AutocompleteFieldObserver {
    enum Change {
        /// The text or the cursor of a field changed.
        case text
        /// Another field (or window) has the focus.
        case focus
    }

    private var observer: AXObserver?
    private var element: AXUIElement?
    private(set) var pid: pid_t?
    private let changed: (Change) -> Void

    private static let textNotifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]
    private static let focusNotifications = [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification]

    init(changed: @escaping (Change) -> Void) { self.changed = changed }

    /// Watches the app with `pid`, and stops watching the one before it.
    func watch(_ pid: pid_t?) {
        guard pid != self.pid else { return }
        stop()
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, fieldObserverCallback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Registered on the app: it passes on what its fields and windows send.
        for name in Self.textNotifications + Self.focusNotifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        element = app
        self.pid = pid
    }

    func stop() {
        if let observer, let element {
            for name in Self.textNotifications + Self.focusNotifications {
                AXObserverRemoveNotification(observer, element, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        element = nil
        pid = nil
    }

    fileprivate func received(_ name: String) {
        changed(Self.focusNotifications.contains(name) ? .focus : .text)
    }
}
