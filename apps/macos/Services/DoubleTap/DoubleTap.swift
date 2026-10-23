import AppKit
import ApplicationServices
import Combine

/// Double Tap: tap the chosen key twice (right ⌘ by default) and a small field in the notch asks what Nook should do
/// (`onAsk`). Typing "fill in the form" there (`DoubleTapLogic.asksToFill`) fills the empty fields of the form or reply
/// box in front with what Nook remembers about you and the text on screen (`fill(request:)`). See `DoubleTapLogic` for
/// the rules of filling. Asking it to write ("schrijf een sollicitatiebrief", "translate this", `DoubleTapLogic.asksToWrite`)
/// types the text where the cursor is, in any app: a Word document, a mail, a note, a chat (`write(request:)`). Asking it
/// to change a part that is there ("punt 5 moet dit worden", "maak de tweede alinea korter", `DoubleTapLogic.asksToEdit`)
/// finds that part in the document, selects it with the accessibility layer, the mouse or the keyboard, and types the new
/// text over it (`edit(request:)`). Anything else goes to the chat, where Nook can take the task over with mouse and keyboard.
///
/// - The key is watched with NSEvent `flagsChanged` monitors only: no event tap, so no Input Monitoring prompt.
/// - Fields are read and written through the accessibility layer of the app in front; Nook never presses Return and never
///   types into a password field or into apps that hold passwords or run commands (`UIControl.isBlocked`).
/// - Every step (reading the app, thinking, what Nook is about to type) shows in the notch with Stop (`onStep`).
///   Open the notch (or press Steps on the result) and every step of the run is listed there with what Nook typed,
///   changed or filled in, while it works and after it is done, so you can check it (`run`, `DoubleTapRunBar`).
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
    /// The run Nook is on, or the last one, with every step and what it typed, changed or filled in: the open notch
    /// shows it (`DoubleTapRunBar`), also once it is done, so you can check what happened.
    @Published private(set) var run: DoubleTapRun?

    /// Nook's brain: system prompt, question, timeout → the answer, or nil. Set by `AppModel`.
    var ask: ((String, String, Double) async -> String?)?
    /// What Nook remembers about the user, as the active brain may see it.
    var facts: () -> [String] = { [] }
    /// The text Nook read on screen in this app (bundle id), as the active brain may see it.
    var screenText: (String) -> String? = { _ in nil }
    /// Shows the result as a card that waits for the user. Set by `AppModel`; without it the result is a toast.
    var present: ((DoubleTapOutcome) -> Void)?
    /// The notch asks what Nook should do (`AppModel.presentTakeoverPrompt`): on a double tap, and on one tap when
    /// `taskOnTap` is on.
    var onAsk: (() -> Void)?
    /// The step Nook is on, in the notch with Stop (`AppModel.startDoubleTap`); without it the pill shows the step.
    var onStep: ((String) -> Void)?
    /// The steps are over; `last` is the last step shown, so a result shown since is left alone.
    var onStepsEnd: ((_ last: String) -> Void)?
    /// Opens the notch on the steps of the run (Steps on its result). Set by `AppModel`.
    var showSteps: (() -> Void)?
    /// What is on the clipboard, as the active brain may see it ("punt 5 moet dit worden" after copying the new text).
    var clipboardText: () -> String? = { nil }
    /// Nook's own cursor where it acts in the document (screen point, top-left origin), and nil when it is done.
    var showCursor: ((CGPoint?, String) -> Void)?
    /// Writes a line to the audit log: what was asked, what happened.
    var record: ((_ args: String, _ result: String) -> Void)?
    /// One tap gives Nook a task (Settings › Shortcuts).
    @Published var taskOnTap: Bool {
        didSet { defaults.set(taskOnTap, forKey: "takeoverOnTap") }
    }

    /// A local model may take a while on a long form; past this the double tap gives up.
    static let deadline: Double = 60
    /// How long a finished run stays in the open notch when you do not close it.
    static let keepRun: Double = 15 * 60

    private let defaults = UserDefaults.standard
    private var gesture = DoubleTapGesture()
    /// Counts taps, so a single tap knows whether a second one followed.
    private var tapCount = 0
    private var monitors: [Any] = []
    private var task: Task<Void, Never>?
    private let pill = FlowPill()
    /// The last step shown, for `onStepsEnd`.
    private var lastStep = ""

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
        tapCount += 1
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
            tapCount += 1
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
        // A new press of the key ends the wait of an earlier single tap, also when its release comes late.
        if down { tapCount += 1 }
        switch gesture.update(down: down, alone: alone, at: now, lastKeyDown: now - sinceKey) {
        case .double:
            tapCount += 1
            // Nook asks what to do rather than guessing that a form must be filled in; "fill in the form" is one answer.
            if let onAsk { onAsk() } else { fill() }
        case .tap:
            // One tap: give Nook a task, once it is clear no second tap follows.
            tapCount += 1
            let tap = tapCount
            guard taskOnTap, onAsk != nil else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(DoubleTapGesture.window * 1_000_000_000) + 50_000_000)
                guard let self, self.tapCount == tap else { return }
                self.onAsk?()
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

    /// Fills the form in front. `request`: what the user typed in the notch ("vul het formulier in met mijn werkadres");
    /// `delay`: time for the app the user was in to get the keyboard back after the notch's field closed. A request while
    /// Nook is still filling is ignored: two answers would land in the same fields.
    func fill(request: String = "", after delay: Double = 0) {
        start(request: request, after: delay) { [weak self] in await self?.runFill(request: request) }
    }

    /// Writes what the user asked for ("schrijf een sollicitatiebrief", "vertaal dit naar het Engels") where the cursor
    /// is, in whatever app is in front: a document, a mail, a note, a chat. Selected text is replaced. `fallback` runs
    /// when there is no cursor in a text to write at, so the request goes to the chat instead of getting lost.
    func write(request: String, after delay: Double = 0, fallback: (() -> Void)? = nil) {
        start(request: request, after: delay) { [weak self] in await self?.runWrite(request: request, fallback: fallback) }
    }

    /// Changes the part of the document in front that the user names ("punt 5 moet dit worden", "verwijder de laatste
    /// zin"): selected and typed over the way a person would. When the brain finds nothing to change it writes at the cursor
    /// instead; `fallback` runs when there is no document to edit, so the request goes to the chat (and from there to a
    /// task Nook takes over) instead of getting lost.
    func edit(request: String, after delay: Double = 0, fallback: (() -> Void)? = nil) {
        start(request: request, after: delay) { [weak self] in await self?.runEdit(request: request, fallback: fallback) }
    }

    /// Stop in the notch: the brain's answer is no longer typed.
    func stop() {
        task?.cancel()
    }

    /// The notch closed while Nook works: the step it is on shows under the notch again, without waiting for the next.
    func showStepAgain() {
        guard run?.isRunning == true, !lastStep.isEmpty else { return }
        onStep?(lastStep)
    }

    /// The closed run's OK in the notch: its steps go. A run that still works stays.
    func dismissRun() {
        guard run?.isRunning == false else { return }
        run = nil
    }

    private func start(request: String, after delay: Double, _ body: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        let id = UUID()
        run = DoubleTapRun(id: id, request: request)
        task = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self else { return }
            self.isFilling = true
            await body()
            // A way out without a result of its own (Stop, no app in front) still ends the run.
            let stopped = Task.isCancelled
            self.finishRun(stopped ? .stopped : .info, tr(stopped ? "doubletap.run.stopped" : "doubletap.run.ended"))
            self.isFilling = false
            self.endSteps()
            self.task = nil
            self.forget(id)
        }
    }

    /// A finished run leaves the notch after `keepRun`, unless a new one took its place.
    private func forget(_ id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.keepRun * 1_000_000_000))
            guard let self, self.run?.id == id, self.run?.isRunning == false else { return }
            self.run = nil
        }
    }

    /// Shows what Nook is doing now: in the notch when the app shows it there, else in the pill.
    private func step(_ line: String) {
        lastStep = line
        run?.step(line)
        if let onStep { onStep(line) } else { pill.show(.message(line)) }
    }

    /// The result: it ends the run, which keeps its steps, and shows as a toast with Steps to see them again (unless the
    /// toast has an action of its own: Undo, Open Settings).
    private func report(_ kind: NookToastKind, _ title: String, detail: String? = nil, action: NookToastAction? = nil) {
        finishRun(Self.outcome(of: kind), title, detail: detail ?? "")
        ToastCenter.shared.show(title, detail: detail, kind: kind, action: action ?? stepsAction)
    }

    private func finishRun(_ outcome: DoubleTapRun.Outcome, _ result: String, detail: String = "") {
        run?.finish(outcome, result: result, detail: detail)
    }

    /// Steps on a result: the notch opens on how Nook got there and what it typed.
    private var stepsAction: NookToastAction? {
        guard let showSteps, run?.steps.isEmpty == false else { return nil }
        return NookToastAction(title: tr("doubletap.steps.show"), perform: showSteps)
    }

    private static func outcome(of kind: NookToastKind) -> DoubleTapRun.Outcome {
        switch kind {
        case .success: return .done
        case .info: return .info
        case .warning, .error: return .failed
        }
    }

    /// The request goes to the chat after all, which follows it in the notch itself.
    private func handOff(_ fallback: () -> Void) {
        finishRun(.info, tr("doubletap.run.chat"))
        fallback()
    }

    private func endSteps() {
        pill.hide()
        if !lastStep.isEmpty { onStepsEnd?(lastStep) }
        lastStep = ""
    }

    private func runFill(request: String) async {
        guard AXIsProcessTrusted() else {
            return report(.warning, tr("doubletap.noAccess"), action: NookToastAction(title: tr("doubletap.openSettings")) {
                SystemPermission.accessibility.openSettings()
            })
        }
        guard let ask else { return report(.warning, tr("doubletap.noBrain")) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appName = app.localizedName ?? ""
        guard !UIControl.isBlocked(app: appName, bundleID: app.bundleIdentifier) else {
            return report(.info, tr("doubletap.blocked", appName))
        }
        run?.app = appName
        step(tr("doubletap.step.reading", appName))
        DoubleTapForm.wake(app)
        // A document or a text that is not a form (Word, Pages, a note): "fill this in" writes at the cursor there.
        guard let form = DoubleTapForm.read(app) else {
            return await writeInstead(request: request, app: app, otherwise: tr("doubletap.noField"))
        }
        if form.focusIsSecure { return report(.info, tr("doubletap.secure")) }
        let fields = DoubleTapLogic.candidates(form.fields.map(\.field))
        guard DoubleTapLogic.hasRoom(fields) else {
            // Every field is filled. In a text box or document (Word's page is one big text area) the cursor is where
            // the text goes; in a form whose fields are all filled, there is nothing to do.
            let focus = form.fields.first(where: \.field.focused)?.field
            guard focus?.isMultiline ?? true else { return report(.info, tr("doubletap.nothingEmpty")) }
            return await writeInstead(request: request, app: app, otherwise: tr("doubletap.nothingEmpty"))
        }

        step(tr("doubletap.step.fields", fields.count))
        let screen = screenText(app.bundleIdentifier ?? "") ?? ""
        let prompt = DoubleTapLogic.prompt(app: appName, window: form.title, fields: fields, facts: facts(), screen: screen,
                                           request: request)
        let reply = await ask(DoubleTapLogic.system, prompt, Self.deadline)
        guard !Task.isCancelled else { return }
        guard let reply else { return report(.warning, tr("doubletap.failed")) }
        let values = DoubleTapLogic.values(from: reply, fields: fields)
        guard !values.isEmpty else { return report(.info, tr("doubletap.nothing")) }

        // The fields may have changed while the brain thought: write only where the same app is still in front.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return report(.info, tr("doubletap.moved"))
        }
        step(tr("doubletap.working"))
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
        guard count > 0 else { return report(.warning, tr("doubletap.writeFailed", appName)) }
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
        let title = count == 1 ? tr("doubletap.filledOne", appName) : tr("doubletap.filled", count, appName)
        for item in filled { run?.check(item.label.isEmpty ? tr("doubletap.card.field") : item.label, item.value) }
        if let present {
            // The card shows what was filled in; the run keeps it with its steps for the open notch.
            finishRun(.done, title, detail: tr(submit == nil ? "doubletap.notSent" : "doubletap.card.check"))
            present(outcome)
        } else {
            report(.success, title, detail: tr("doubletap.notSent"), action: undo.map { undo in
                NookToastAction(title: tr("doubletap.undo"), perform: undo)
            })
        }
    }

    // MARK: Writing at the cursor

    private func runWrite(request: String, fallback: (() -> Void)?) async {
        guard AXIsProcessTrusted() else {
            return report(.warning, tr("doubletap.noAccess"), action: NookToastAction(title: tr("doubletap.openSettings")) {
                SystemPermission.accessibility.openSettings()
            })
        }
        guard ask != nil else { return report(.warning, tr("doubletap.noBrain")) }
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own else {
            return noCursor(fallback)
        }
        let appName = app.localizedName ?? ""
        guard !UIControl.isBlocked(app: appName, bundleID: app.bundleIdentifier) else {
            return report(.info, tr("doubletap.write.blocked", appName))
        }
        run?.app = appName
        step(tr("doubletap.step.reading", appName))
        DoubleTapForm.wake(app)
        guard let cursor = await Self.cursor(in: app) else { return noCursor(fallback) }
        await write(request: request, at: cursor, in: app)
    }

    // MARK: Editing what is there

    private func runEdit(request: String, fallback: (() -> Void)?) async {
        guard AXIsProcessTrusted() else {
            return report(.warning, tr("doubletap.noAccess"), action: NookToastAction(title: tr("doubletap.openSettings")) {
                SystemPermission.accessibility.openSettings()
            })
        }
        guard let ask else { return report(.warning, tr("doubletap.noBrain")) }
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own else { return noCursor(fallback) }
        let appName = app.localizedName ?? ""
        guard !UIControl.isBlocked(app: appName, bundleID: app.bundleIdentifier) else {
            return report(.info, tr("doubletap.write.blocked", appName))
        }
        run?.app = appName
        step(tr("doubletap.step.reading", appName))
        DoubleTapForm.wake(app)
        guard !DoubleTapForm.focusIsSecure(app), let document = DoubleTapDocument.read(app) else { return noCursor(fallback) }

        step(tr("doubletap.step.thinking", DoubleTapLogic.preview(request)))
        let screen = screenText(app.bundleIdentifier ?? "") ?? ""
        let prompt = DoubleTapLogic.editPrompt(request: request, app: appName, window: document.title, document: document.text,
                                               cursor: document.selection, clipboard: clipboardText() ?? "", facts: facts(),
                                               screen: screen)
        let reply = await ask(DoubleTapLogic.editSystem, prompt, Self.deadline)
        guard !Task.isCancelled else { return }
        guard let reply else { return report(.warning, tr("doubletap.edit.failed")) }
        let (edits, missed) = DoubleTapLogic.edits(from: reply, in: document.text)
        guard !edits.isEmpty else {
            // The part is not there as the brain wrote it: the chat reads the window itself and takes it over.
            if missed > 0 {
                if let fallback { return handOff(fallback) }
                return report(.info, tr("doubletap.edit.notFound"))
            }
            // Nothing there to change: new text after all ("schrijf de inleiding"), else a task for the chat ("verander de
            // achtergrond in blauw"), which Nook can take over with mouse and keyboard.
            guard DoubleTapLogic.asksToWrite(request), let cursor = await Self.cursor(in: app) else { return noCursor(fallback) }
            return await write(request: request, at: cursor, in: app)
        }

        // What Nook is about to change stays in the notch for a moment, so Stop can still keep it out.
        step(tr("doubletap.step.editing", appName, DoubleTapLogic.editPreview(edits[edits.count - 1])))
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return report(.info, tr("doubletap.moved"))
        }
        // The user may have typed while the brain thought: find each part again in the document as it is now.
        guard let now = document.current() else { return report(.warning, tr("doubletap.edit.refused", appName)) }
        var fresh = document
        fresh.text = now
        let placed = edits.compactMap { edit -> DoubleTapEdit? in
            guard let range = DoubleTapLogic.locate(edit.find, in: now) else { return nil }
            return DoubleTapEdit(find: (now as NSString).substring(with: range), replace: edit.replace, range: range)
        }.sorted { $0.range.location > $1.range.location }

        var changed = 0
        for (index, edit) in placed.enumerated() {
            guard !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { break }
            step(tr("doubletap.step.editing", appName, DoubleTapLogic.editPreview(edit)))
            if await fresh.apply(edit, in: app, show: { [weak self] point, label in self?.showCursor?(point, label) }) {
                changed += 1
                run?.check("“" + DoubleTapLogic.preview(edit.find) + "”",
                           edit.replace.isEmpty ? tr("doubletap.run.removed") : edit.replace)
            }
            // The clipboard gets back what it held before the next paste takes it.
            if index < placed.count - 1 { try? await Task.sleep(nanoseconds: 800_000_000) }
        }
        showCursor?(nil, "")
        record?(request, "\(changed)/\(edits.count) changed in \(appName)")
        if changed == 0 {
            // The app would not let Nook select the text this way: the chat takes the task over with mouse and keyboard.
            if let fallback { return handOff(fallback) }
            report(.warning, tr("doubletap.edit.refused", appName))
        } else if changed < edits.count {
            report(.info, tr("doubletap.editedSome", changed, edits.count, appName), detail: tr("doubletap.typed.undo"))
        } else {
            report(.success, tr("doubletap.edited", appName), detail: tr("doubletap.typed.undo"))
        }
    }

    private func noCursor(_ fallback: (() -> Void)?) {
        if let fallback { handOff(fallback) } else { report(.info, tr("doubletap.noField")) }
    }

    /// "Fill this in" where there is no form to fill: write at the cursor when there is one, else say `otherwise`.
    private func writeInstead(request: String, app: NSRunningApplication, otherwise: String) async {
        guard let cursor = await Self.cursor(in: app) else { return report(.info, otherwise) }
        let asked = request.trimmingCharacters(in: .whitespacesAndNewlines)
        await write(request: asked.isEmpty ? "Fill this in for me." : asked, at: cursor, in: app)
    }

    /// The text around the cursor, when the focus of the app in front is a text that takes typing: nil when it is not
    /// (the desktop, a list, a button) or when it is a password field. An app that keeps its text from the accessibility
    /// layer (some Electron apps) but has a text focus gives an empty snapshot: Nook writes without the context.
    private static func cursor(in app: NSRunningApplication) async -> AutocompleteFieldSnapshot? {
        guard !DoubleTapForm.focusIsSecure(app) else { return nil }
        let height = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map(\.frame)
        if let snapshot = await Task.detached(operation: { AutocompleteField.read(screenHeight: height, screens: screens) }).value {
            return snapshot
        }
        guard FlowPaste.focusTakesText() == true else { return nil }
        return AutocompleteFieldSnapshot(before: "", after: "", hasSelection: false, caret: nil)
    }

    private func write(request: String, at cursor: AutocompleteFieldSnapshot, in app: NSRunningApplication) async {
        guard let ask else { return report(.warning, tr("doubletap.noBrain")) }
        let appName = app.localizedName ?? ""
        step(tr("doubletap.step.thinking", DoubleTapLogic.preview(request)))
        let screen = screenText(app.bundleIdentifier ?? "") ?? ""
        let prompt = DoubleTapLogic.writePrompt(request: request, app: appName, window: cursor.windowTitle ?? "",
                                                before: cursor.before, after: cursor.after, selected: cursor.selectedText,
                                                facts: facts(), screen: screen)
        let reply = await ask(DoubleTapLogic.writeSystem, prompt, Self.deadline)
        guard !Task.isCancelled else { return }
        guard let reply else { return report(.warning, tr("doubletap.write.failed")) }
        guard let text = DoubleTapLogic.written(from: reply) else { return report(.info, tr("doubletap.write.nothing")) }

        // What Nook is about to type stays in the notch for a moment, so Stop can still keep it out.
        step(tr("doubletap.step.typing", appName, DoubleTapLogic.preview(text)))
        try? await Task.sleep(nanoseconds: 800_000_000)
        guard !Task.isCancelled else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return report(.info, tr("doubletap.moved"))
        }
        switch FlowPaste.insert(text) {
        case .pasted:
            run?.check(tr("doubletap.run.typed"), text)
            report(.success, tr("doubletap.typed", appName), detail: tr("doubletap.typed.undo"))
        case .noAccess:
            report(.warning, tr("doubletap.noAccess"), action: NookToastAction(title: tr("doubletap.openSettings")) {
                SystemPermission.accessibility.openSettings()
            })
        case .noField:
            report(.warning, tr("doubletap.write.refused", appName))
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

    /// Whether the cursor is in a password field of the app.
    static func focusIsSecure(_ app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 1.0)
        guard let focused = element(root, kAXFocusedUIElementAttribute) else { return false }
        return string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole || string(focused, kAXRoleAttribute) == "AXSecureTextField"
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
