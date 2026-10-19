import AppKit
import ApplicationServices
import Carbon
import SwiftUI

/// Flow: hold a key anywhere on the Mac, speak, let go, and the words are pasted where you type. Two quick taps keep
/// listening hands-free until the next tap; Esc cancels; ⌃⌘V pastes the last dictation again.
///
/// Nook listens in your languages at once (MultiDictation, on-device), puts your dictionary, replacements and snippets in,
/// and cleans the words with your own brain, on this Mac by default, so the words never leave it unless you chose an
/// external brain. Watching the key and pasting need the Accessibility permission. Off until you turn it on.
///
/// The flow after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
@MainActor
final class FlowDictation: ObservableObject {
    static let shared = FlowDictation()

    /// How long the microphone stays open after the key comes up, so the last word makes it in.
    static let tailNanoseconds: UInt64 = 600_000_000

    @Published private(set) var trusted = AXIsProcessTrusted()
    let pill = FlowPill()

    /// Rewrites with Nook's brain: system prompt, text, timeout → the rewritten text, or nil.
    var rewrite: ((String, String, Double) async -> String?)?

    private let store = FlowStore.shared
    private var logic = FlowKeyLogic()
    private var monitors: [Any] = []
    private var current: Listen?
    private var startTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?
    private var promptedThisRun = false

    private init() {}

    /// At launch, and whenever Flow is turned on or off or its key changes.
    func refresh() {
        removeMonitors()
        trusted = AXIsProcessTrusted()
        guard store.enabled else {
            cancelAll()
            trustTask?.cancel()
            trustTask = nil
            return
        }
        installMonitors()
        if !trusted { waitForTrust() }
        Parakeet.shared.preload()
    }

    func askForAccessibility() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted { waitForTrust() }
    }

    /// The "Allow" button. Asking macOS first is what puts Nook in the list in System Settings; opening the pane alone shows a
    /// list without Nook in it.
    func openAccessibilitySettings() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted {
            SystemPermission.accessibility.openSettings()
            waitForTrust()
        }
        PermissionMonitor.shared.refresh()
    }

    /// Hands-free from a button (the pill, Settings' "Try it").
    func startHandsFree() {
        guard store.enabled, logic.phase == .idle, current == nil else { return }
        logic.lock()
        begin()
    }

    // MARK: The key

    private func installMonitors() {
        // A global monitor sees the key in other apps, a local one while Nook itself is in front.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags, event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2, characters: info.3) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags, event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2, characters: info.3) }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// Until macOS trusts Nook, the global monitor gets nothing: check every 2 s and reinstall the monitors once it does.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.store.enabled else { return }
                if AXIsProcessTrusted() {
                    self.trusted = true
                    self.removeMonitors()
                    self.installMonitors()
                    return
                }
            }
        }
    }

    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown:
            let mods = flags.intersection([.command, .control, .option, .shift])
            if keyCode == UInt16(kVK_Escape) { apply(logic.escape()) }
            else if logic.phase == .idle, mods == [.command, .control], characters?.lowercased() == "v" { pasteAgain() }
            else { apply(logic.otherKey()) }
        case .flagsChanged where keyCode == store.key.keyCode:
            apply(store.key.isDown(rawFlags: flags.rawValue) ? logic.keyDown(at: now) : logic.keyUp(at: now))
        default:
            break
        }
    }

    private func apply(_ action: FlowKeyLogic.Action) {
        switch action {
        case .none: break
        case .start: begin()
        case .restart: abort(); begin()
        case .lock: pill.show(.locked)
        case .finish: finish()
        case .cancel: abort()
        }
        if case .tapWait(let until) = logic.phase { scheduleTick(at: until) }
    }

    private func scheduleTick(at until: Double) {
        tickTask?.cancel()
        let wait = max(0, until - ProcessInfo.processInfo.systemUptime) + 0.02
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.logic.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    // MARK: Listening

    /// One listen, from the key press to the paste. Cancelling it drops its words.
    @MainActor private final class Listen {
        /// The Mac's recognizer in your languages, or Parakeet when it is downloaded and on (Settings).
        let apple: MultiDictation?
        let parakeet: ParakeetDictation?

        init(useParakeet: Bool) {
            apple = useParakeet ? nil : MultiDictation()
            parakeet = useParakeet ? ParakeetDictation() : nil
        }

        var isRecording: Bool { apple?.isRecording ?? parakeet?.isRecording ?? false }
        /// Parakeet writes everything at the end: no live words.
        var transcript: String { apple?.transcript ?? "" }

        func start() async {
            if let apple { await apple.start(from: "") } else if let parakeet { await parakeet.start() }
        }

        func finish() async -> String {
            if let apple { return await apple.finish() }
            if let parakeet { return await parakeet.finish() }
            return ""
        }

        func stop() {
            apple?.stop()
            parakeet?.stop()
        }

        func onLevel(_ handler: @escaping @MainActor (Double) -> Void) {
            apple?.onLevel = handler
            parakeet?.onLevel = handler
        }
        var cancelled = false
        /// The app the words go to, seen when the key went down.
        let app = NSWorkspace.shared.frontmostApplication
        let startedAt = Date()
        var stoppedAt: Date?
    }

    private func begin() {
        let listen = Listen(useParakeet: Parakeet.shared.inUse)
        current = listen
        pill.show(logic.phase == .locked ? .locked : .listening)
        listen.onLevel { [weak self] level in self?.pill.level = level }
        startTask = Task { @MainActor [weak self] in
            await listen.start()
            guard let self else { return }
            if listen.cancelled { listen.stop(); return }
            if !listen.isRecording, self.current === listen {
                // No permission, no recognizer for these languages, or no microphone.
                self.logic.reset()
                self.current = nil
                self.pill.flash(tr("flow.pill.noMic"))
            }
        }
        // Live words in the pill while you speak.
        Task { @MainActor [weak self] in
            while let self, self.current === listen, !listen.cancelled {
                // Only a change redraws the pill: it is published, and you often pause while speaking.
                let words = listen.transcript
                if self.pill.words != words { self.pill.words = words }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func finish() {
        guard let listen = current else { pill.hide(); return }
        pill.show(.thinking)
        listen.stoppedAt = Date()
        let opening = startTask
        Task { @MainActor [weak self] in
            await opening?.value
            try? await Task.sleep(nanoseconds: Self.tailNanoseconds)
            guard !listen.cancelled else { return }
            let heard = await listen.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !listen.cancelled else { return }
            let text = await self.shape(heard, app: listen.app)
            guard !listen.cancelled else { return }
            if !text.isEmpty {
                let spoken = (listen.stoppedAt ?? Date()).timeIntervalSince(listen.startedAt)
                self.store.record(text: text, app: listen.app?.localizedName, seconds: spoken)
            }
            let latest = self.current === listen
            if latest { self.current = nil }
            guard !text.isEmpty else { if latest { self.pill.hide() }; return }
            let result = FlowPaste.insert(text)
            if latest { self.pill.hide() }
            switch result {
            case .pasted: break
            case .noAccess:
                self.trusted = false
                if !self.promptedThisRun { self.promptedThisRun = true; self.askForAccessibility() }
                self.pill.flash(tr("flow.pill.noAccess"))
            case .noField:
                self.pill.flash(tr("flow.pill.copied"))
            }
        }
    }

    /// The dictionary and replacements, then the brain's clean-up (or prompt or translation), then the snippets.
    func shape(_ heard: String, app: NSRunningApplication?) async -> String {
        let prepared = store.prepare(heard)
        var body = prepared.text
        let style = store.style(for: app?.bundleIdentifier)
        let transform = store.promptMode || !store.translateTo.isEmpty
        if !body.isEmpty, let rewrite, transform || (store.cleanup && style != .verbatim && FlowText.wordCount(body) >= 3) {
            let system = FlowCleanup.system(style: style, prompt: store.promptMode, language: store.translateTo.isEmpty ? nil : store.translateTo,
                                            app: app?.localizedName, words: store.words)
            if let reply = await rewrite(system, FlowCleanup.prompt(body), store.promptMode ? 15 : 6) {
                let out = FlowCleanup.clean(reply: reply)
                let plausible = transform ? FlowCleanup.plausibleTransform(out, from: body, prompt: store.promptMode)
                    : FlowCleanup.plausible(out, from: body)
                if plausible, FlowText.keepsMarks(out, prepared.snippets) { body = out }
            }
        }
        return FlowText.finish(body, snippets: prepared.snippets)
    }

    func pasteAgain() {
        guard let text = store.lastText, !text.isEmpty else { return }
        if FlowPaste.insert(text) == .noAccess { pill.flash(tr("flow.pill.noAccess")) }
    }

    private func abort() {
        tickTask?.cancel()
        if let listen = current {
            listen.cancelled = true
            listen.stop()
        }
        current = nil
        pill.hide()
    }

    private func cancelAll() {
        logic.reset()
        abort()
    }
}

// MARK: - Paste

/// Puts the words where the cursor is: on the clipboard, then ⌘V, then the clipboard gets back what it held.
/// after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
enum FlowPaste {
    /// Marks the words as passing through, so clipboard managers leave them out of their history (nspasteboard.org).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    enum Result { case pasted, noAccess, noField }

    @MainActor static func insert(_ text: String) -> Result {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        board.declareTypes([.string, transientType, autoGeneratedType], owner: nil)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: transientType)
        board.setData(Data(), forType: autoGeneratedType)
        guard AXIsProcessTrusted() else { return .noAccess }
        let field = focusTakesText()

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = vKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if field == false { return .noField }
        // Give the app time to read the clipboard, then put back what was there, unless something else was copied.
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard board.changeCount == count else { return }
            restore(saved, to: board)
        }
        return .pasted
    }

    /// True for a text field, false only where text clearly never goes (the desktop, a list, a button), nil when it
    /// cannot be told: Chromium and Electron apps often report no focused element while their text box has the focus.
    @MainActor static func focusTakesText() -> Bool? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .noValue { return front == "com.apple.finder" ? false : nil }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String
        if let role, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"].contains(role) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success { return true }
        let notText: Set<String> = ["AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXBrowser", "AXImage", "AXButton",
                                    "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXMenu", "AXMenuItem",
                                    "AXMenuBar", "AXMenuBarItem", "AXDockItem"]
        if let role, notText.contains(role) { return false }
        return nil
    }

    /// The key that types "v" with ⌘ in the current keyboard layout (QWERTY, AZERTY, Dvorak…); QWERTY's otherwise.
    @MainActor static func vKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let found: CGKeyCode? = data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), commandState,
                                            UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                            &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == 0x76 { return CGKeyCode(code) }
            }
            return nil
        }
        return found ?? fallback
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type] = data } }
            return out
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        guard !items.isEmpty else { return }
        board.writeObjects(items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }
}

// MARK: - The pill

/// A small see-through pill at the bottom of the screen while Flow listens: a dot that moves with your voice and the
/// words as they are heard. It never takes the focus away from where you type.
@MainActor
final class FlowPill: ObservableObject {
    enum Phase: Equatable { case hidden, listening, locked, thinking, message(String) }

    @Published private(set) var phase: Phase = .hidden
    @Published var level: Double = 0
    @Published var words = ""

    private var panel: NSPanel?
    private var flashTask: Task<Void, Never>?

    func show(_ phase: Phase) {
        flashTask?.cancel()
        if phase == .listening || phase == .locked { words = "" }
        self.phase = phase
        present()
    }

    func hide() {
        flashTask?.cancel()
        phase = .hidden
        level = 0
        panel?.orderOut(nil)
    }

    /// A short message (no microphone, copied instead of pasted), then the pill goes away.
    func flash(_ text: String) {
        show(.message(text))
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = NSSize(width: 420, height: 64)
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 18, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: FlowPillView(pill: self))
        return panel
    }
}

private struct FlowPillView: View {
    @ObservedObject var pill: FlowPill

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 10 + 10 * pill.level, height: 10 + 10 * pill.level)
                .frame(width: 22, height: 22)
                .animation(.easeOut(duration: 0.12), value: pill.level)
            Text(line)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var color: Color {
        switch pill.phase {
        case .thinking: return Color(red: 0.62, green: 0.58, blue: 1)
        case .message: return Color(red: 1, green: 0.72, blue: 0.3)
        default: return Color(red: 0.36, green: 0.9, blue: 0.68)
        }
    }

    private var line: String {
        switch pill.phase {
        case .hidden: return ""
        case .listening, .locked:
            if !pill.words.isEmpty { return pill.words }
            return pill.phase == .locked ? tr("flow.pill.handsFree") : tr("flow.pill.listening")
        case .thinking: return tr("flow.pill.thinking")
        case .message(let text): return text
        }
    }
}
