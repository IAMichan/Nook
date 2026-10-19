import AppKit
import Carbon.HIToolbox
import IOKit.ps

/// Autocomplete anywhere: while you type in any app, a model on this Mac suggests how the sentence goes on, as grey text at
/// the cursor. Tab takes the next word, ⇧Tab all of it; typing what was suggested keeps the rest; any other key sends it
/// away. Also: emoji by name (`:lachen`), a fix for the word you just mistyped, and other words for a selected word.
///
/// The text before the cursor is read through the Accessibility API, given to the model on this Mac and forgotten again.
/// Password fields are never read, and nothing runs while macOS Secure Input is on. The model is a GGUF file: by default the
/// one Cotypist downloaded, or one Nook downloads itself.
///
/// The flow (key watcher → short pause → read the field → proposal → overlay) follows Typist's coordinator (MIT, © 2026
/// Brody Salvucci). Nook adds what it knows: your memory and the text it already reads on screen.
@MainActor
final class AutocompleteController: ObservableObject {
    static let shared = AutocompleteController()

    enum State: Equatable {
        case off, noAccess, noModel, loading, ready
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// Cotypist's models and Nook's own, newest first.
    @Published private(set) var candidates: [CompletionModelFile] = []
    @Published private(set) var activeModel: CompletionModelFile?
    @Published private(set) var trusted = AXIsProcessTrusted()
    /// Apps typed in since launch (bundle id → name), for the per-app settings.
    @Published private(set) var seenApps: [String: String] = [:]
    @Published private(set) var lastSite: String?

    /// What Nook's memory knows about the user (set by AppModel).
    var facts: () -> [String] = { [] }
    /// The text Nook already read in the front window of this app (set by AppModel).
    var screenText: (_ bundleID: String) -> String? = { _ in nil }

    private struct Completion {
        var suggestion: CompletionSuggestion
        /// The text before the cursor this suggestion continues; grows as words are taken or typed through.
        var anchor: String
        /// Until its first word is taken (for the statistics).
        var fresh = true
    }

    private enum Proposal {
        case completion(Completion)
        /// Replace the last `delete` characters with `insert` (emoji, typo fix).
        case replacement(delete: Int, insert: String)
    }

    private let store = AutocompleteStore.shared
    private let overlay = GhostOverlay()
    private let builder = PromptBuilder()
    /// Accessibility answers can take tens of milliseconds; the key tap is on the main thread, so reading happens here.
    private let readQueue = DispatchQueue(label: "nl.imdigital.nook.autocomplete.read", qos: .userInteractive)
    /// Goes up with everything the user does; results of older reads are dropped.
    private var readToken = 0

    private var proposal: Proposal?
    private var alternatives: [String]?
    private var refreshWork: DispatchWorkItem?
    private var selectionWork: DispatchWorkItem?
    private var pendingSample: (app: String, text: String)?
    private var batteryCheck: (date: Date, onBattery: Bool)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var appObserver: NSObjectProtocol?
    private var pressure: DispatchSourceMemoryPressure?
    private var trustTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private var completer: LlamaCompleter?
    private var loading: Task<LlamaCompleter?, Never>?

    /// How often to re-read the field while the app takes in a key, and how many times.
    private let settleInterval: TimeInterval = 0.03
    private let settleAttempts = 12
    /// The model leaves memory after this long without a suggestion.
    private static let idleSeconds: UInt64 = 15 * 60

    private var prefs: CompletionPreferences { store.prefs }

    private init() {}

    // MARK: Starting

    /// At launch, and whenever autocomplete is turned on or off or its model changes.
    func refresh() {
        trustTask?.cancel()
        trustTask = nil
        trusted = AXIsProcessTrusted()
        guard prefs.enabled else {
            stop()
            state = .off
            return
        }
        Task {
            let folder = AutocompleteStore.modelsFolder
            let found = await Task.detached(priority: .utility) {
                CompletionModelLocator.cotypistModels() + CompletionModelLocator.nookModels(in: folder)
            }.value
            candidates = found
            let model = CompletionModelLocator.resolve(storedPath: prefs.modelPath, candidates: found)
            if model?.url.path != activeModel?.url.path { unload() }
            activeModel = model
            guard prefs.enabled else { return }
            guard trusted, start() else {
                state = .noAccess
                waitForTrust()
                return
            }
            guard let model else { state = .noModel; return }
            state = .ready
            // Load it now, so the first suggestion does not wait.
            if completer == nil, await loadedCompleter(for: model) != nil { scheduleUnload() }
        }
    }

    func askForAccessibility() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted { waitForTrust() }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Writes the last field's text as a sample (at quit).
    func flush() { commitSample() }

    /// Until macOS trusts Nook there is no key tap: check every 2 s and start once it does.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.prefs.enabled else { return }
                if AXIsProcessTrusted() { self.refresh(); return }
            }
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<AutocompleteController>.fromOpaque(refcon).takeUnretainedValue()
        let swallow = MainActor.assumeIsolated { controller.handle(type: type, event: event) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    /// An active tap (not only a listener): the accept keys must not reach the app as an ordinary Tab.
    private func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.leftMouseDown.rawValue
            | 1 << CGEventType.rightMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: Self.tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appChanged(app) }
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.unload() } }
        pressure.resume()
        self.pressure = pressure
        if let app = frontApp { readQueue.async { AutocompleteField.wake(app) } }
        return true
    }

    private func stop() {
        dismiss()
        commitSample()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        pressure?.cancel()
        tap = nil
        tapSource = nil
        appObserver = nil
        pressure = nil
        unload()
    }

    private func appChanged(_ app: NSRunningApplication?) {
        if let app { readQueue.async { AutocompleteField.wake(app) } }
        store.offUntilSwitch = nil
        lastSite = nil
        commitSample()
        dismiss()
    }

    // MARK: State

    private var frontApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    private var ownAppInFront: Bool { frontApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier }

    private var onBattery: Bool {
        if let batteryCheck, Date().timeIntervalSince(batteryCheck.date) < 30 { return batteryCheck.onBattery }
        var value = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            value = (type as String) == kIOPMBatteryPowerKey
        }
        batteryCheck = (Date(), value)
        return value
    }

    private func isActive(in app: NSRunningApplication?) -> Bool {
        guard let app, !ownAppInFront, !IsSecureEventInputEnabled(), activeModel != nil else { return false }
        let bundleID = app.bundleIdentifier
        return prefs.isEnabled(inApp: bundleID) && !store.isPaused(app: bundleID) && !(prefs.pauseOnBattery && onBattery)
    }

    var isPausedEverywhere: Bool { store.isPaused(app: nil) }

    func togglePauseEverywhere() {
        if store.isPaused(app: nil) { store.resume() } else { store.pause(minutes: nil); dismiss() }
    }

    func togglePause(app bundleID: String) {
        if store.isPaused(app: bundleID) { store.resume(app: bundleID) }
        else { store.pause(app: bundleID, seconds: Double(prefs.pauseMinutes * 60)); dismiss() }
    }

    // MARK: Input

    private struct Key {
        var code: Int
        var flags: CGEventFlags
        var characters: String

        var modifiers: Int {
            var result = 0
            if flags.contains(.maskCommand) { result |= CompletionShortcut.command }
            if flags.contains(.maskAlternate) { result |= CompletionShortcut.option }
            if flags.contains(.maskControl) { result |= CompletionShortcut.control }
            if flags.contains(.maskShift) { result |= CompletionShortcut.shift }
            return result
        }

        func matches(_ shortcut: CompletionShortcut?) -> Bool { shortcut?.matches(keyCode: code, modifiers: modifiers) ?? false }
    }

    /// True swallows the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown, .rightMouseDown:
            dismiss()
            return false
        case .leftMouseUp:
            scheduleSelectionCheck()
            return false
        case .keyDown:
            // What Nook types itself. Some apps lose the mark, so also check who sent it.
            if event.getIntegerValueField(.eventSourceUserData) == AutocompleteTyper.marker
                || event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return false }
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
            let key = Key(code: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                          characters: String(utf16CodeUnits: buffer, count: length))
            return handle(key)
        default:
            return false
        }
    }

    private func handle(_ key: Key) -> Bool {
        // The shortcut recorder in Settings must see every key.
        if ownAppInFront { return false }
        let app = frontApp
        let bundleID = app?.bundleIdentifier

        if key.matches(prefs.toggleAll) { togglePauseEverywhere(); return true }
        if key.matches(prefs.toggleApp), let bundleID { togglePause(app: bundleID); return true }
        if prefs.wordAlternatives, key.matches(prefs.alternatives) { showAlternatives(); return true }

        guard isActive(in: app) else { dismiss(); return false }
        if let bundleID, seenApps[bundleID] == nil { seenApps[bundleID] = app?.localizedName ?? bundleID }

        let commandLike = !key.flags.intersection([.maskCommand, .maskControl]).isEmpty
        let plainEscape = key.code == kVK_Escape && key.modifiers == 0

        if let alternatives {
            if !commandLike, let number = Int(key.characters), (1...alternatives.count).contains(number) {
                let choice = alternatives[number - 1]
                dismiss()
                AutocompleteTyper.type(choice)
                scheduleRefresh()
                return true
            }
            dismiss()
            if plainEscape { return true }
        }

        if let proposal {
            let tabLeftToApp = prefs.app(bundleID).leaveTab && key.code == kVK_Tab
            let acceptWord = key.matches(prefs.acceptWord) && !tabLeftToApp
            let acceptAll = key.matches(prefs.acceptAll) && !tabLeftToApp
            switch proposal {
            case .completion(var completion):
                if acceptWord || acceptAll {
                    let options = CompletionSuggestion.AcceptOptions(trailingSpace: prefs.trailingSpace, attachedPunctuation: prefs.attachedPunctuation)
                    let text = acceptAll ? completion.suggestion.acceptAll() : completion.suggestion.acceptNextChunk(options)
                    accept(text, leaving: completion)
                    return true
                }
                // Typing exactly what was suggested keeps the suggestion.
                if !commandLike, completion.suggestion.consume(typed: key.characters), !completion.suggestion.isEmpty {
                    completion.anchor += key.characters
                    self.proposal = .completion(completion)
                    settle()
                    return false
                }
            case .replacement(let delete, let insert):
                if acceptWord || acceptAll {
                    dismiss()
                    AutocompleteTyper.replace(last: delete, with: insert)
                    store.recordAccepted(insert, first: true)
                    scheduleRefresh()
                    return true
                }
            }
            dismiss()
            if plainEscape {
                escaped(in: bundleID)
                return true
            }
        }

        scheduleRefresh()
        if key.flags.contains(.maskShift) { scheduleSelectionCheck() }
        return false
    }

    /// Types `text`. What is left of the suggestion stays: the word lands where its ghost was, so the overlay only moves once
    /// the app has caught up, without a flicker or a new model call.
    private func accept(_ raw: String, leaving rest: Completion) {
        let text = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled ? CompletionTypography.smartQuotes(raw, after: rest.anchor.last) : raw
        AutocompleteTyper.type(text)
        store.recordAccepted(text, first: rest.fresh)
        if rest.suggestion.isEmpty {
            proposal = nil
            overlay.hide()
            scheduleRefresh()
        } else {
            var rest = rest
            rest.anchor += text
            rest.fresh = false
            proposal = .completion(rest)
            settle()
        }
    }

    private func dismiss() {
        readToken += 1
        refreshWork?.cancel()
        selectionWork?.cancel()
        completer?.cancel()
        proposal = nil
        alternatives = nil
        overlay.hide()
    }

    private func escaped(in bundleID: String?) {
        guard let bundleID else { return }
        switch prefs.escape {
        case .dismiss: break
        case .pauseBriefly: store.pause(app: bundleID, seconds: 10)
        case .offUntilAppSwitch: store.offUntilSwitch = bundleID
        }
    }

    // MARK: Proposals

    private func scheduleRefresh() {
        refreshWork?.cancel()
        completer?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshProposal() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(max(prefs.delayMilliseconds, 30)) / 1000, execute: work)
    }

    /// Reads the field on the reading queue; `done` runs on the main queue unless the user did something else meanwhile.
    private func read(in app: NSRunningApplication, done: @escaping (AutocompleteFieldSnapshot?) -> Void) {
        let token = readToken
        let height = NSScreen.screens.first?.frame.height ?? 0
        readQueue.async {
            let snapshot = AutocompleteField.read(screenHeight: height)
            // Chromium and Electron build their tree on request: ask again so the next key finds the field.
            if snapshot == nil { AutocompleteField.wake(app) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if token == self.readToken { done(snapshot) } }
            }
        }
    }

    private func refreshProposal() {
        guard let app = frontApp, isActive(in: app) else { return }
        read(in: app) { [weak self] snapshot in
            if let snapshot { self?.propose(for: snapshot, in: app) }
        }
    }

    private func propose(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication) {
        lastSite = snapshot.site
        guard prefs.isEnabled(onSite: snapshot.site) else { return }
        record(snapshot, app: app.bundleIdentifier)
        if snapshot.hasSelection { return }
        if !prefs.smallFields, let field = snapshot.fieldFrame, field.width > 0, field.width < 150 { return }

        if prefs.emoji, let caret = snapshot.caret, let query = CompletionEmojiCatalog.query(in: snapshot.before),
           let emoji = CompletionEmojiCatalog.search(query, limit: 1).first {
            let rendered = CompletionEmojiCatalog.render(emoji, skinTone: prefs.skinTone)
            proposal = .replacement(delete: query.count + 1, insert: rendered)
            overlay.showCard(card("\(rendered)  :\(emoji.shortcodes[0]):"), below: caret)
            return
        }

        if prefs.typos, let fix = AutocompleteTypos.fix(for: snapshot.before) {
            // Never build a suggestion on a likely typo.
            if prefs.showTypoFixes, let caret = snapshot.caret {
                proposal = .replacement(delete: fix.deleteCount, insert: fix.replacement)
                let text = NSMutableAttributedString(string: fix.original, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                text.append(NSAttributedString(string: "  " + fix.corrected, attributes: [.foregroundColor: NSColor.labelColor]))
                overlay.showCard(card(text), below: caret)
            }
            return
        }

        requestCompletion(for: snapshot, in: app)
    }

    private func requestCompletion(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier
        let midLine = prefs.midLine(inApp: bundleID)
        let policy = CompletionPolicy(midLine: midLine)
        guard let model = activeModel, policy.shouldComplete(before: snapshot.before, after: snapshot.after, hasSelection: snapshot.hasSelection) else { return }
        var maxWords = prefs.maxWords
        if prefs.shorterOnBattery, onBattery { maxWords = min(maxWords, 4) }
        let options = CompletionOptions(maxWords: maxWords, eagerness: prefs.eagerness)
        let prompt = self.prompt(for: snapshot, in: app)
        let token = readToken
        Task {
            guard let completer = await loadedCompleter(for: model), token == readToken else { return }
            let result = await completer.complete(prompt: prompt, options: options)
            scheduleUnload()
            guard let result, token == readToken, proposal == nil, alternatives == nil,
                  let suggestion = CompletionSuggestion.make(raw: result.text, before: snapshot.before, after: midLine ? snapshot.after : "",
                                                             maxWords: maxWords, truncated: result.truncated) else { return }
            proposal = .completion(Completion(suggestion: suggestion, anchor: snapshot.before))
            show(suggestion, for: snapshot, in: app)
            store.recordShown()
        }
    }

    private func prompt(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication) -> String {
        let bundleID = app.bundleIdentifier
        var input = CompletionContext(before: snapshot.before)
        input.instructions = prefs.instructions(app: bundleID, site: snapshot.site)
        if prefs.memoryContext { input.facts = Array(facts().prefix(8)) }
        if prefs.windowContext {
            input.appName = app.localizedName
            input.windowTitle = snapshot.windowTitle
            input.fieldHint = snapshot.placeholder
            input.site = snapshot.site
        }
        if prefs.screenContext, let bundleID {
            // Leave out the field's own text: it is already the body of the prompt.
            input.screenText = screenText(bundleID).map { CompletionPrivacy.sanitize($0.replacingOccurrences(of: snapshot.before, with: "")) }
        }
        if prefs.clipboardContext {
            let board = NSPasteboard.general
            // Password managers mark secrets as concealed: leave those alone.
            let concealed = board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false
            if !concealed { input.clipboard = board.string(forType: .string).map(CompletionPrivacy.sanitize) }
        }
        if prefs.learn, prefs.personalStrength > 0, let bundleID { input.samples = store.samples.relevant(for: bundleID, limit: 2) }
        return builder.build(input)
    }

    /// After typing or taking part of a suggestion: waits until the app's text is what the rest continues, then moves the
    /// overlay to the new cursor.
    private func settle(attempt: Int = 0) {
        if attempt == 0 { readToken += 1 }
        guard case .completion = proposal, let app = frontApp, isActive(in: app) else { return }
        read(in: app) { [weak self] snapshot in
            guard let self, case .completion(let completion) = self.proposal else { return }
            if let snapshot, !snapshot.hasSelection, snapshot.before == completion.anchor {
                self.show(completion.suggestion, for: snapshot, in: app)
            } else if attempt < self.settleAttempts {
                let token = self.readToken
                DispatchQueue.main.asyncAfter(deadline: .now() + self.settleInterval) {
                    MainActor.assumeIsolated { if token == self.readToken { self.settle(attempt: attempt + 1) } }
                }
            } else {
                // The app did something else with the text (autocorrect, formatting): start over.
                self.dismiss()
                self.scheduleRefresh()
            }
        }
    }

    private func show(_ suggestion: CompletionSuggestion, for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication) {
        let rule = prefs.app(app.bundleIdentifier)
        if let caret = snapshot.caret {
            if prefs.inlineGhost {
                overlay.showGhost(suggestion.remaining, at: caret, fontScale: rule.fontScale, verticalOffset: rule.verticalOffset)
            } else {
                overlay.showCard(card(suggestion.remaining.trimmingCharacters(in: .whitespaces)), below: caret)
            }
        } else if let field = snapshot.fieldFrame {
            // The app does not say where the cursor is: under the field instead.
            overlay.showCard(card(suggestion.remaining.trimmingCharacters(in: .whitespaces)), below: field)
        } else {
            proposal = nil
            overlay.hide()
        }
    }

    private func card(_ text: String) -> NSAttributedString {
        card(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
    }

    /// The font and the accept-key hint every card has.
    private func card(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.append(NSAttributedString(string: "   " + prefs.acceptWord.label, attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
        result.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Other words

    private func scheduleSelectionCheck() {
        selectionWork?.cancel()
        guard prefs.wordAlternatives, prefs.autoAlternatives else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showAlternatives() } }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Words to pick by number: for the selected word, or, without a selection, instead of the word Nook would suggest next.
    private func showAlternatives() {
        guard let app = frontApp, isActive(in: app) else { return }
        var suggested = ""
        if case .completion(let completion) = proposal { suggested = completion.suggestion.nextChunk().trimmingCharacters(in: .whitespaces) }
        dismiss()
        read(in: app) { [weak self] snapshot in
            if let snapshot { self?.showAlternatives(for: snapshot, in: app, suggested: suggested) }
        }
    }

    private func showAlternatives(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication, suggested: String) {
        let anchor: CGRect?
        let current: String
        if snapshot.hasSelection {
            guard CompletionTextAnalysis.isSingleWord(snapshot.selectedText) else { return }
            anchor = snapshot.selectionRect ?? snapshot.caret
            current = snapshot.selectedText.trimmingCharacters(in: .whitespaces)
        } else {
            anchor = snapshot.caret ?? snapshot.fieldFrame
            current = suggested
        }
        guard let anchor, let model = activeModel else { return }
        let token = readToken
        // After a space only whole words fit; in the middle of a word, only ways to finish it.
        let afterSpace = snapshot.before.last?.isWhitespace ?? true
        let prompt = self.prompt(for: snapshot, in: app)
        Task {
            guard let completer = await loadedCompleter(for: model) else { return }
            let words = await completer.alternatives(prompt: prompt, excluding: current, count: 10)
            guard proposal == nil, token == readToken else { return }
            let capitalized = snapshot.hasSelection && (current.first?.isUppercase ?? false)
            let choices = words
                .filter { $0.hasPrefix(" ") == afterSpace || snapshot.before.isEmpty }
                .map { afterSpace ? String($0.drop { $0 == " " }) : $0 }
                .map { capitalized ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
                .prefix(5)
            guard !choices.isEmpty else { return }
            alternatives = Array(choices)
            let text = NSMutableAttributedString()
            for (index, choice) in choices.enumerated() {
                text.append(NSAttributedString(string: "\(index + 1)  ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor]))
                text.append(NSAttributedString(string: choice + (index < choices.count - 1 ? "\n" : ""), attributes: [.foregroundColor: NSColor.labelColor]))
            }
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: text.length))
            overlay.showCard(text, below: anchor)
        }
    }

    // MARK: Learning

    private func record(_ snapshot: AutocompleteFieldSnapshot, app bundleID: String?) {
        guard prefs.learn, let bundleID, prefs.app(bundleID).learn else { return }
        let text = snapshot.before + snapshot.after
        // Much shorter text: the field was emptied (message sent) or another field has the focus. Keep what was written.
        if let pendingSample, pendingSample.app != bundleID || text.count < pendingSample.text.count / 2 { commitSample() }
        pendingSample = (bundleID, text)
    }

    private func commitSample() {
        guard let sample = pendingSample else { return }
        pendingSample = nil
        if store.addSample(sample.text, app: sample.app) { applyPersonalization() }
    }

    /// Hands the words the user writes often to the model.
    func applyPersonalization() {
        completer?.setPersonalization(words: prefs.learn ? store.samples.vocabulary() : [:], strength: prefs.learn ? prefs.personalStrength : 0)
    }

    // MARK: The model

    private func loadedCompleter(for model: CompletionModelFile) async -> LlamaCompleter? {
        if let completer, completer.path == model.url.path { return completer }
        if let loading { return await loading.value }
        state = .loading
        let task = Task { () -> LlamaCompleter? in
            do {
                let loaded = try await LlamaCompleter.load(path: model.url.path)
                completer = loaded
                applyPersonalization()
                state = .ready
                return loaded
            } catch {
                state = .failed(error.localizedDescription)
                return nil
            }
        }
        loading = task
        let result = await task.value
        loading = nil
        return result
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    private func unload() {
        idleTask?.cancel()
        completer?.cancel()
        completer = nil
    }
}
