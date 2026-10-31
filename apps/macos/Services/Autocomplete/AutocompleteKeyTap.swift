import AppKit
import Carbon.HIToolbox

/// The key tap's callback. At file level: a C function pointer cannot carry context; `refcon` is the `AutocompleteKeyTap`.
/// Runs on the tap's own thread.
private let autocompleteTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    if let refcon { Unmanaged<AutocompleteKeyTap>.fromOpaque(refcon).takeUnretainedValue().observe(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}

/// Autocomplete's event tap: one that only listens, the way Cotypist's does. macOS hands it a copy of each key and click
/// and never waits for it, so nothing Nook does (the notch redrawing, a model loading, a slow main thread) can hold up
/// typing in another app. The keys autocomplete takes from the app (accept, Escape, the picker's keys) are system hot keys,
/// registered only while they mean something (see `AutocompleteHotKeys`); this tap only tells the controller what was typed
/// and clicked, so it can follow along.
final class AutocompleteKeyTap: @unchecked Sendable {
    enum Event {
        /// A key typed by the user, already on its way to the app.
        case key(CompletionKeyPress, flags: CGEventFlags)
        /// Where the click is, in global display coordinates (top left origin).
        case mouseDown(at: CGPoint)
        case mouseUp
    }

    private let lock = NSLock()
    private let deliver: (Event) -> Void
    /// Written on the main thread under `lock`; the tap thread reads `port` under it too.
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    /// - Parameter deliver: called on the main queue for every key and click.
    init(deliver: @escaping (Event) -> Void) {
        self.deliver = deliver
    }

    /// Creates the tap and starts its thread. False when macOS refuses the tap (no Input Monitoring).
    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.leftMouseDown.rawValue
            | 1 << CGEventType.rightMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
        guard let newPort = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                              callback: autocompleteTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0) else { return false }
        locked {
            port = newPort
            source = newSource
        }
        let ready = DispatchSemaphore(value: 0)
        // The thread keeps the tap alive (and with it the callback's `refcon`) until its run loop ends in `stop`.
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            locked { runLoop = loop }
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
        let loop = locked { runLoop }
        if let loop, let source { CFRunLoopRemoveSource(loop, source, .commonModes) }
        CFMachPortInvalidate(port)
        // With its only source gone the run loop returns by itself; stopping it covers a run loop that is between two turns.
        if let loop { CFRunLoopStop(loop) }
        locked {
            self.port = nil
            source = nil
        }
    }

    // MARK: On the tap thread

    fileprivate func observe(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // A listening tap holds nothing up, but macOS still turns off one that falls far behind.
            Log.autocomplete.info("Key tap disabled (\(type.rawValue)); enabling it again")
            if let port = locked({ self.port }) { CGEvent.tapEnable(tap: port, enable: true) }
        case .keyDown:
            // What Nook types itself. Some apps lose the mark, so also check who sent it.
            if event.getIntegerValueField(.eventSourceUserData) == AutocompleteTyper.marker
                || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
            send(.key(Self.press(event), flags: event.flags))
        case .leftMouseDown, .rightMouseDown:
            send(.mouseDown(at: type == .leftMouseDown ? event.location : .init(x: -1, y: -1)))
        case .leftMouseUp:
            send(.mouseUp)
        default:
            break
        }
    }

    /// The key of a key event: its code, the modifiers held and the characters it types on the current layout.
    static func press(_ event: CGEvent) -> CompletionKeyPress {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return CompletionKeyPress(code: Int(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers(event.flags),
                                  characters: String(utf16CodeUnits: buffer, count: length))
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [self] in deliver(event) }
    }

    private func locked<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
