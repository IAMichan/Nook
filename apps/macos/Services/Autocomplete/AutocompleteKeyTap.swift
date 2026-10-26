import AppKit
import Carbon.HIToolbox

/// The key tap's callback. At file level: a C function pointer cannot carry context; `refcon` is the `AutocompleteKeyTap`.
/// Runs on the tap's own thread.
private let autocompleteTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<AutocompleteKeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.filter(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Autocomplete's event tap: an active one (not only a listener), so the accept keys do not reach the app as an ordinary Tab.
///
/// An active tap holds every key and click on the Mac until its callback returns. So it runs on a thread of its own, with its
/// own run loop, and the callback never waits for the main thread: it decides from a small copy of the controller's state
/// (`CompletionKeyGate`, kept up to date with `publish`) whether the event must not reach the app, and hands everything else
/// to the main thread asynchronously. A hitch on the main thread (the notch redrawing, reading the screen) then no longer
/// becomes input lag in every app.
///
/// The main thread handles the keys in the order they came and tells the tap when it did (`resolved`). Until then the tap
/// cannot know what those keys changed, so it errs on the side of keeping a key back: a key kept back that should have gone
/// to the app is posted again by the main thread (`Event.key`'s `copy`), in order, so it only arrives a moment later; a key
/// let through cannot be taken back.
final class AutocompleteKeyTap: @unchecked Sendable {
    enum Event {
        /// A key typed by the user. `swallowed`: kept from the app. `copy` (marked as Nook's own, see `AutocompleteTyper.marker`)
        /// is the key to post when it must reach the app after all.
        case key(CompletionKeyPress, flags: CGEventFlags, swallowed: Bool, copy: CGEvent?)
        /// `emoji`: a click on that emoji of the picker, kept from the app (its mouse up too).
        case mouseDown(emoji: Int?)
        case mouseUp
    }

    private struct Shared {
        var gate = CompletionKeyGate()
        /// A click that took an emoji: its mouse up does not reach the app either.
        var swallowMouseUp = false
        /// Keys handed to the main thread and not handled there yet, and how many of them were kept from the app.
        var pending = 0
        var pendingSwallowed = 0
    }

    private let lock = NSLock()
    private var shared = Shared()
    private let deliver: (AutocompleteKeyTap, Event) -> Void
    /// Written on the main thread under `lock`; the tap thread reads `port` under it too.
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    /// - Parameter deliver: called on the main queue for every event the main thread should know about, with the tap it
    ///   came from (to report back to with `resolved`).
    init(deliver: @escaping (AutocompleteKeyTap, Event) -> Void) {
        self.deliver = deliver
    }

    /// Creates the tap and starts its thread. False when macOS refuses the tap (no Accessibility or Input Monitoring).
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.leftMouseDown.rawValue
            | 1 << CGEventType.rightMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
        guard let newPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: autocompleteTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0) else { return false }
        locked { _ in
            port = newPort
            source = newSource
        }
        let ready = DispatchSemaphore(value: 0)
        // The thread keeps the tap alive (and with it the callback's `refcon`) until its run loop ends in `stop`.
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            locked { _ in runLoop = loop }
            CFRunLoopAddSource(loop, newSource, .commonModes)
            CGEvent.tapEnable(tap: newPort, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "nl.imdigital.nook.autocomplete.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Only the moment it takes to start a thread: `stop` needs its run loop.
        ready.wait()
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        let loop = locked { _ in runLoop }
        if let loop, let source { CFRunLoopRemoveSource(loop, source, .commonModes) }
        CFMachPortInvalidate(port)
        // With its only source gone the run loop returns by itself; stopping it covers a run loop that is between two turns.
        if let loop { CFRunLoopStop(loop) }
        locked { _ in
            self.port = nil
            source = nil
        }
    }

    /// The controller's state as the tap needs it. Called on the main thread whenever it changes.
    func publish(_ gate: CompletionKeyGate) {
        locked { $0.gate = gate }
    }

    /// The main thread handled a key from `Event.key`, and the state after it.
    func resolved(swallowed: Bool, gate: CompletionKeyGate) {
        locked {
            $0.gate = gate
            $0.pending = max($0.pending - 1, 0)
            if swallowed { $0.pendingSwallowed = max($0.pendingSwallowed - 1, 0) }
        }
    }

    // MARK: On the tap thread

    /// True keeps the event from the app.
    fileprivate func filter(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a tap off when its callback takes too long. It should not happen any more now that the callback never
            // waits for the main thread; when it does, it is worth knowing.
            if type == .tapDisabledByTimeout {
                Log.autocomplete.error("Key tap disabled by timeout; enabling it again")
            } else {
                Log.autocomplete.info("Key tap disabled by user input; enabling it again")
            }
            if let port = locked({ _ in self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .keyDown:
            return filterKey(event)
        case .leftMouseDown, .rightMouseDown:
            var emoji: Int?
            if type == .leftMouseDown {
                let location = event.location
                emoji = locked { shared in
                    guard let index = shared.gate.emojiCell(at: location) else { return nil }
                    shared.swallowMouseUp = true
                    return index
                }
            }
            send(.mouseDown(emoji: emoji))
            return emoji != nil
        case .leftMouseUp:
            let swallow = locked { shared in
                defer { shared.swallowMouseUp = false }
                return shared.swallowMouseUp
            }
            if !swallow { send(.mouseUp) }
            return swallow
        default:
            return false
        }
    }

    private func filterKey(_ event: CGEvent) -> Bool {
        // What Nook types itself. Some apps lose the mark, so also check who sent it.
        if event.getIntegerValueField(.eventSourceUserData) == AutocompleteTyper.marker
            || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        let flags = event.flags
        let key = CompletionKeyPress(code: Int(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: Self.modifiers(flags),
                                     characters: String(utf16CodeUnits: buffer, count: length))

        let now = locked { $0 }
        var gate = now.gate
        if gate.active, IsSecureEventInputEnabled() { gate.active = false }
        // An accept key is held, or a key before this one is still kept back: this one goes after it, in order, through the
        // main thread. Otherwise the gate decides; while keys are on their way to the main thread, an accept key that could
        // start a wait for a suggestion is kept back too (the main thread posts it again when nothing is coming).
        var swallow = gate.holding || now.pendingSwallowed > 0 || gate.swallows(key) || (now.pending > 0 && gate.mayHold(key))
        var copy: CGEvent?
        if swallow {
            copy = event.copy()
            copy?.setIntegerValueField(.eventSourceUserData, value: AutocompleteTyper.marker)
            // Without a copy the key could never reach the app later: let it through now.
            if copy == nil { swallow = false }
        }
        locked {
            $0.pending += 1
            if swallow { $0.pendingSwallowed += 1 }
        }
        send(.key(key, flags: flags, swallowed: swallow, copy: copy))
        return swallow
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [self] in deliver(self, event) }
    }

    private func locked<Result>(_ body: (inout Shared) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&shared)
    }

    /// The modifiers held, as `CompletionShortcut` bits.
    static func modifiers(_ flags: CGEventFlags) -> Int {
        var result = 0
        if flags.contains(.maskCommand) { result |= CompletionShortcut.command }
        if flags.contains(.maskAlternate) { result |= CompletionShortcut.option }
        if flags.contains(.maskControl) { result |= CompletionShortcut.control }
        if flags.contains(.maskShift) { result |= CompletionShortcut.shift }
        return result
    }
}
