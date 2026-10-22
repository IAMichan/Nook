import AppKit
import ApplicationServices
import Combine

/// Double Tap: tap the chosen key twice (right ⌘ by default) with the cursor in a form or a reply box, and Nook fills the
/// empty fields with what it remembers about you and the text on screen. See `DoubleTapLogic` for the rules.
///
/// - The key is watched with NSEvent `flagsChanged` monitors only: no event tap, so no Input Monitoring prompt.
/// - Fields are read and written through the accessibility layer of the app in front; Nook never presses Return and never
///   types into a password field or into apps that hold passwords or run commands (`UIControl.isBlocked`).
/// - The result is a card in the notch with what was filled, Undo (which empties the fields again) and, when the form has
///   a send button, Send: the form is only sent when the user presses it there. Buttons that pay, order or delete are
///   never offered.
@MainActor
final class DoubleTap: ObservableObject {
    static let shared = DoubleTap()

    /// On by default: two taps of a key alone do nothing else on a Mac.
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "doubleTapEnabled"); refresh() }
    }
    @Published var key: FlowKey {
        didSet { defaults.set(key.rawValue, forKey: "doubleTapKey"); refresh() }
    }
    @Published private(set) var isFilling = false

    /// Nook's brain: system prompt, question, timeout → the answer, or nil. Set by `AppModel`.
    var ask: ((String, String, Double) async -> String?)?
    /// What Nook remembers about the user, as the active brain may see it.
    var facts: () -> [String] = { [] }
    /// The text Nook read on screen in this app (bundle id), as the active brain may see it.
    var screenText: (String) -> String? = { _ in nil }
    /// Shows the result as a card that waits for the user. Set by `AppModel`; without it the result is a toast.
    var present: ((DoubleTapOutcome) -> Void)?
    /// One tap of the key: the notch asks what Nook should do (`AppModel.presentTakeoverPrompt`).
    var onTap: (() -> Void)?
    /// One tap gives Nook a task (Settings › Shortcuts).
    @Published var taskOnTap: Bool {
        didSet { defaults.set(taskOnTap, forKey: "takeoverOnTap") }
    }

    /// A local model may take a while on a long form; past this the double tap gives up.
    static let deadline: Double = 60

    private let defaults = UserDefaults.standard
    private var gesture = DoubleTapGesture()
    /// Counts taps, so a single tap knows whether a second one followed.
    private var tapCount = 0
    private var monitors: [Any] = []
    private var task: Task<Void, Never>?
    private let pill = FlowPill()

    private init() {
        enabled = defaults.object(forKey: "doubleTapEnabled") as? Bool ?? true
        key = FlowKey(rawValue: defaults.string(forKey: "doubleTapKey") ?? "") ?? .rightCommand
        taskOnTap = defaults.object(forKey: "takeoverOnTap") as? Bool ?? true
    }

    /// Flow owns a key it dictates with: holding it and tapping it both mean something there.
    var conflictsWithFlow: Bool {
        FlowStore.shared.enabled && FlowStore.shared.key == key
    }

    /// At launch (after the app finished launching), and whenever Double Tap, its key or Flow's key changes.
    func refresh() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        gesture.interrupt()
        guard enabled else { return }
        // Monitors added while the app is still launching never receive events: try again once it runs.
        guard NSApp?.isRunning == true else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.refresh()
            }
            return
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let info = (event.keyCode, event.modifierFlags.rawValue)
            MainActor.assumeIsolated { self?.handle(keyCode: info.0, rawFlags: info.1) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            let info = (event.keyCode, event.modifierFlags.rawValue)
            MainActor.assumeIsolated { self?.handle(keyCode: info.0, rawFlags: info.1) }
            return event
        }) { monitors.append(local) }
    }

    private func handle(keyCode: UInt16, rawFlags: UInt) {
        guard keyCode == key.keyCode else {
            gesture.interrupt()
            return
        }
        guard !conflictsWithFlow else { return }
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let down = key.isDown(rawFlags: rawFlags)
        let held = flags.intersection(others).subtracting(Self.modifier(of: key))
        let alone = (down ? held.isEmpty : flags.intersection(others).isEmpty) && NSEvent.pressedMouseButtons == 0
        let now = ProcessInfo.processInfo.systemUptime
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        switch gesture.update(down: down, alone: alone, at: now, lastKeyDown: now - sinceKey) {
        case .double:
            tapCount += 1
            fill()
        case .tap:
            // One tap: give Nook a task, once it is clear no second tap follows.
            tapCount += 1
            let tap = tapCount
            guard taskOnTap, onTap != nil else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(DoubleTapGesture.window * 1_000_000_000) + 50_000_000)
                guard let self, self.tapCount == tap else { return }
                self.onTap?()
            }
        case .none:
            break
        }
    }

    private static func modifier(of key: FlowKey) -> NSEvent.ModifierFlags {
        switch key {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }

    // MARK: Filling

    /// One double tap. A tap while Nook is still filling is ignored: two answers would land in the same fields.
    func fill() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isFilling = true
            await self.run()
            self.isFilling = false
            self.pill.hide()
            self.task = nil
        }
    }

    private func run() async {
        guard AXIsProcessTrusted() else {
            return ToastCenter.shared.warning(tr("doubletap.noAccess"), action: NookToastAction(title: tr("doubletap.openSettings")) {
                SystemPermission.accessibility.openSettings()
            })
        }
        guard let ask else { return ToastCenter.shared.warning(tr("doubletap.noBrain")) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? ""
        guard !UIControl.isBlocked(app: appName, bundleID: app.bundleIdentifier) else {
            return ToastCenter.shared.info(tr("doubletap.blocked", appName))
        }
        DoubleTapForm.wake(app)
        guard let form = DoubleTapForm.read(app) else { return ToastCenter.shared.info(tr("doubletap.noField")) }
        if form.focusIsSecure { return ToastCenter.shared.info(tr("doubletap.secure")) }
        let fields = DoubleTapLogic.candidates(form.fields.map(\.field))
        guard DoubleTapLogic.hasRoom(fields) else { return ToastCenter.shared.info(tr("doubletap.nothingEmpty")) }

        pill.show(.message(tr("doubletap.working")))
        let screen = screenText(app.bundleIdentifier ?? "") ?? ""
        let prompt = DoubleTapLogic.prompt(app: appName, window: form.title, fields: fields, facts: facts(), screen: screen)
        guard let reply = await ask(DoubleTapLogic.system, prompt, Self.deadline), !Task.isCancelled else {
            return ToastCenter.shared.warning(tr("doubletap.failed"))
        }
        let values = DoubleTapLogic.values(from: reply, fields: fields)
        guard !values.isEmpty else { return ToastCenter.shared.info(tr("doubletap.nothing")) }

        // The fields may have changed while the brain thought: write only where the same app is still in front.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return ToastCenter.shared.info(tr("doubletap.moved"))
        }
        var written: [DoubleTapForm.Entry] = []
        var pasted = false
        for field in fields {
            guard let value = values[field.id], form.fields.indices.contains(field.source) else { continue }
            let entry = form.fields[field.source]
            if DoubleTapForm.write(value, to: entry) {
                written.append(entry)
            } else if field.focused, case .pasted = FlowPaste.insert(value) {
                // Some editors (Electron, custom text views) take pasted text but refuse a written value.
                pasted = true
            }
        }
        let count = written.count + (pasted ? 1 : 0)
        guard count > 0 else { return ToastCenter.shared.warning(tr("doubletap.writeFailed", appName)) }
        let filled = fields.compactMap { field in values[field.id].map { (label: field.label, value: $0) } }
        let undo: (() -> Void)? = written.isEmpty ? nil : {
            for entry in written { _ = DoubleTapForm.write("", to: entry) }
        }
        var submit: DoubleTapOutcome.Submit?
        if let button = form.submit {
            let pid = app.processIdentifier
            submit = DoubleTapOutcome.Submit(label: button.label) {
                // Pressed from the card: the same app must still run, and the button must still be there to press.
                guard NSRunningApplication(processIdentifier: pid) != nil else { return false }
                return AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success
            }
        }
        let outcome = DoubleTapOutcome(app: appName, count: count, filled: filled, undo: undo, submit: submit)
        if let present {
            present(outcome)
        } else {
            let title = count == 1 ? tr("doubletap.filledOne", appName) : tr("doubletap.filled", count, appName)
            ToastCenter.shared.success(title, detail: tr("doubletap.notSent"), action: undo.map { undo in
                NookToastAction(title: tr("doubletap.undo"), perform: undo)
            })
        }
    }
}

/// What one double tap filled in, for the card that shows it.
struct DoubleTapOutcome {
    struct Submit {
        /// The button's own label ("Send", "Sign up").
        var label: String
        /// Presses it; false when the app or the button is gone.
        var perform: () -> Bool
    }

    var app: String
    var count: Int
    var filled: [(label: String, value: String)]
    var undo: (() -> Void)?
    var submit: Submit?
}

// MARK: - The form in front

/// The text fields of the focused window of one app, read through the accessibility layer, with the elements to write to.
@MainActor
struct DoubleTapForm {
    struct Entry {
        var field: DoubleTapField
        var element: AXUIElement
    }

    struct Button {
        var label: String
        var element: AXUIElement
    }

    var title: String
    var fields: [Entry]
    var focusIsSecure: Bool
    /// The button that sends this form (`DoubleTapLogic.submitButton`), if there is one.
    var submit: Button?

    private static let maxNodes = 4_000
    private static let maxDepth = 40
    private static let maxFields = 80
    private static let maxButtons = 80

    /// Chromium and Electron build their accessibility tree only for a client that asks.
    static func wake(_ app: NSRunningApplication) {
        AutocompleteField.wake(app)
    }

    /// Nil when the app shows no window or no field.
    static func read(_ app: NSRunningApplication) -> DoubleTapForm? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 1.0)
        let focused: AXUIElement? = element(root, kAXFocusedUIElementAttribute)
        let focusIsSecure = focused.map { (string($0, kAXSubroleAttribute) ?? "") == kAXSecureTextFieldSubrole } ?? false
        guard let window = element(root, kAXFocusedWindowAttribute) ?? focused.flatMap({ element($0, kAXWindowAttribute) }) else {
            return focusIsSecure ? DoubleTapForm(title: "", fields: [], focusIsSecure: true, submit: nil) : nil
        }
        var entries: [Entry] = []
        var buttons: [Button] = []
        var visited = 0
        collect(window, depth: 0, focused: focused, visited: &visited, into: &entries, buttons: &buttons)
        guard !entries.isEmpty || focusIsSecure else { return nil }
        let defaultButton = element(window, kAXDefaultButtonAttribute)
        let defaultIndex = defaultButton.flatMap { target in buttons.firstIndex { CFEqual($0.element, target) } }
        let submit = DoubleTapLogic.submitButton(labels: buttons.map(\.label), defaultIndex: defaultIndex).map { buttons[$0] }
        return DoubleTapForm(title: string(window, kAXTitleAttribute) ?? "", fields: entries, focusIsSecure: focusIsSecure, submit: submit)
    }

    private static func collect(_ node: AXUIElement, depth: Int, focused: AXUIElement?, visited: inout Int, into entries: inout [Entry],
                                buttons: inout [Button]) {
        guard depth <= maxDepth, visited < maxNodes, entries.count < maxFields else { return }
        visited += 1
        let axRole = string(node, kAXRoleAttribute) ?? ""
        if axRole == kAXMenuBarRole { return }
        let subrole = string(node, kAXSubroleAttribute)
        let role = UIControl.role(axRole, subrole: subrole)
        if ["field", "textarea", "combobox", "search", "password"].contains(role) {
            let secure = role == "password" || subrole == kAXSecureTextFieldSubrole
            let enabled = bool(node, kAXEnabledAttribute) ?? true
            if enabled {
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(node, kAXValueAttribute as CFString, &settable)
                let value = secure ? "" : (string(node, kAXValueAttribute) ?? "")
                let isFocused = focused.map { CFEqual($0, node) } ?? false
                entries.append(Entry(field: DoubleTapField(id: entries.count + 1, role: role, label: label(of: node), value: value,
                                                           focused: isFocused, secure: secure, settable: settable.boolValue,
                                                           source: entries.count),
                                     element: node))
            }
            return
        }
        if role == "button" {
            if bool(node, kAXEnabledAttribute) ?? true, buttons.count < maxButtons {
                let name = label(of: node)
                if !name.isEmpty { buttons.append(Button(label: String(name.prefix(80)), element: node)) }
            }
            return
        }
        for child in children(node) {
            collect(child, depth: depth + 1, focused: focused, visited: &visited, into: &entries, buttons: &buttons)
            if visited >= maxNodes || entries.count >= maxFields { return }
        }
    }

    /// The name a person sees for a field: its title, its description (aria-label), the text of its label, its placeholder.
    private static func label(of node: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = string(node, name), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let titled = element(node, kAXTitleUIElementAttribute),
           let text = string(titled, kAXValueAttribute) ?? string(titled, kAXTitleAttribute),
           !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for name in ["AXPlaceholderValue", kAXHelpAttribute] {
            if let text = string(node, name), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    /// Writes a value and reads it back: true only when the field now holds it.
    static func write(_ value: String, to entry: Entry) -> Bool {
        guard !entry.field.secure else { return false }
        let status = AXUIElementSetAttributeValue(entry.element, kAXValueAttribute as CFString, value as CFString)
        guard status == .success else { return false }
        let now = string(entry.element, kAXValueAttribute) ?? ""
        return now.trimmingCharacters(in: .whitespacesAndNewlines) == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Accessibility values

    private static func copy(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = copy(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        copy(node, name) as? String
    }

    private static func bool(_ node: AXUIElement, _ name: String) -> Bool? {
        copy(node, name) as? Bool
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        guard let value = copy(node, kAXChildrenAttribute), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
