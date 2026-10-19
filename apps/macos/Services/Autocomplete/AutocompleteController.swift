import AppKit
import Carbon.HIToolbox
import IOKit.ps

/// The key tap's callback. At file level: a C function pointer may not carry the controller's main-actor isolation. The tap
/// runs on the main run loop, so the controller is entered on the main thread.
private let autocompleteTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AutocompleteController>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { controller.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

/// Autocomplete anywhere: while you type in any app, a model on this Mac suggests how the sentence goes on, as grey text at
/// the cursor. Tab takes the next word, ⇧Tab all of it; typing what was suggested keeps the rest; any other key sends it
/// away. Also: emoji by name (`:lachen`), a fix for the word you just mistyped, and other words for a selected word.
///
/// The text before the cursor is read through the Accessibility API, given to the model on this Mac and forgotten again.
/// Password fields are never read, and nothing runs while macOS Secure Input is on. The model is a GGUF file: by default the
/// one already on this Mac, one Nook downloads itself, or the model Nook's brain downloaded (MLX).
///
/// The flow: key watcher → short pause → read the field → proposal → overlay. Nook adds what it knows: your memory and the
/// text on screen.
@MainActor
final class AutocompleteController: ObservableObject {
    static let shared = AutocompleteController()

    enum State: Equatable {
        case off, noAccess, noModel, loading, ready
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// GGUF models found on this Mac and Nook's own, newest first.
    @Published private(set) var candidates: [CompletionModelFile] = []
    @Published private(set) var activeModel: CompletionSource?
    /// The brain's installed models (MLX), which autocomplete can use too.
    @Published private(set) var brainModels: [(id: String, title: String)] = []
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
        /// The field and app it was made for, to write the next suggestion ahead (see `upcoming`).
        var snapshot: AutocompleteFieldSnapshot
        var app: NSRunningApplication
        var after: String
        var maxWords: Int
    }

    /// The suggestion after the one on screen, written while that one is on screen (see `writeAhead`).
    private struct Upcoming {
        var app: String?
        var before: String
        var task: Task<CompletionResult?, Never>
        /// Set once the model is done: taking the last word then shows it at once.
        var done = false
        var result: CompletionResult?
    }

    private enum Proposal {
        case completion(Completion)
        /// Replace the last `delete` characters with `insert` (typo fix of `word`).
        case replacement(delete: Int, insert: String, word: String)
        /// The emoji picker after a colon: the arrow keys move through `choices`, Tab or Return takes the selected one.
        case emoji(EmojiPicker)
    }

    private struct EmojiPicker {
        var query: String
        var choices: [CompletionEmoji]
        var selected = 0
        var anchor: CGRect
    }

    /// Emoji per row in the picker: 1 to 9 pick from the row with the selection.
    private static let emojiColumns = 9
    /// Marks which emoji a stretch of the picker's text belongs to, for clicks.
    private static let emojiIndexKey = NSAttributedString.Key("nookEmojiIndex")
    /// A click that took an emoji: its mouse up does not reach the app either.
    private var swallowMouseUp = false

    private let store = AutocompleteStore.shared
    private let overlay = GhostOverlay()
    private let builder = PromptBuilder()
    /// Accessibility answers can take tens of milliseconds; the key tap is on the main thread, so reading happens here.
    private let readQueue = DispatchQueue(label: "nl.imdigital.nook.autocomplete.read", qos: .userInteractive)
    /// Goes up with everything the user does; results of older reads are dropped.
    private var readToken = 0

    private var proposal: Proposal?
    /// How the text goes on once the suggestion on screen is taken, written while it is on screen: taking the last word then
    /// shows the next suggestion at once, without waiting for the model.
    private var upcoming: Upcoming?
    /// The context around the typed text, per field (see `prompt(for:in:)`).
    private var fieldContext: (key: String, made: Date, context: CompletionContext)?
    /// The text of the window being written in, read by autocomplete itself (Accessibility), per field (same key as
    /// `fieldContext`). For when Nook's own screen reading has nothing for this app.
    private var windowText: (key: String, text: String?)?
    /// How long the field's text was at the last prompt (same key as `fieldContext`): much shorter means a message was sent.
    private var fieldLength: (key: String, length: Int)?
    /// The clipboard's change count and when Nook first saw it: only something copied in the last minutes says anything
    /// about what is being written.
    private var clipboardSeen: (count: Int, date: Date)?
    private let windowQueue = DispatchQueue(label: "nl.imdigital.nook.autocomplete.window", qos: .utility)
    private var alternatives: [String]?
    private var refreshWork: DispatchWorkItem?
    private var warmWork: DispatchWorkItem?
    private var selectionWork: DispatchWorkItem?
    private var pendingSample: (app: String, text: String)?
    /// Words (lowercased) the typo check leaves alone: the user's own vocabulary, and fixes turned down with Escape.
    private var knownWords: Set<String> = [] { didSet { typoVocabulary = nil } }
    private var ignoredTypos: Set<String> = [] { didSet { typoVocabulary = nil } }
    /// `knownWords` and `ignoredTypos` together for the typo check: built again only when one of them changed, not on
    /// every keystroke (the vocabulary can hold tens of thousands of words).
    private var typoVocabulary: Set<String>?
    private var typoKnown: Set<String> {
        if let typoVocabulary { return typoVocabulary }
        let union = knownWords.union(ignoredTypos)
        typoVocabulary = union
        return union
    }
    private var batteryCheck: (date: Date, onBattery: Bool)?

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var appObserver: NSObjectProtocol?
    private var pressure: DispatchSourceMemoryPressure?
    private var trustTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private var completer: (any CompletionEngine)?
    private var loading: (identity: String, task: Task<(any CompletionEngine)?, Never>)?

    /// How often to re-read the field while the app takes in a key, and how many times.
    private let settleInterval: TimeInterval = 0.03
    private let settleAttempts = 12
    /// The context around a field is gathered again after this long (and after a message is sent).
    private static let contextSeconds: TimeInterval = 180
    /// The clipboard goes into the prompt only this long after it was copied.
    private static let clipboardSeconds: TimeInterval = 5 * 60
    /// The model leaves memory after this long without a suggestion.
    private static let idleSeconds: UInt64 = 15 * 60

    private var prefs: CompletionPreferences { store.prefs }

    private init() {}

    // MARK: Starting

    /// At launch, and whenever autocomplete is turned on or off or its model changes.
    /// A model file was just deleted or moved to the Trash: drop it from the list at once, then look again (scanning the model
    /// folders on this Mac takes a moment).
    func forget(_ url: URL) {
        candidates.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        refresh()
    }

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
                CompletionModelLocator.foundModels() + CompletionModelLocator.nookModels(in: folder)
            }.value
            // A scan that started before a file was deleted still lists it.
            candidates = found.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            brainModels = EmbeddedModel.shared.autocompleteModels
            let preferred = AppSettings.shared.localModel
            let model = CompletionSource.resolve(stored: prefs.modelPath, files: found, brainModels: brainModels, preferredBrain: preferred)
            if model?.identity != activeModel?.identity { unload() }
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
            if case .brain(let id, _) = model { EmbeddedModel.shared.preloadForAutocomplete(id) }
        }
    }

    func askForAccessibility() {
        trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !trusted { waitForTrust() }
    }

    /// The "Allow" button. Asking macOS first is what puts Nook in the list in System Settings; opening the pane alone shows a
    /// list without Nook in it. With Accessibility granted and still no key tap, the missing one is Input Monitoring.
    func openAccessibilitySettings() {
        if AXIsProcessTrusted() {
            if !CGRequestListenEventAccess() { SystemPermission.inputMonitoring.openSettings() }
        } else {
            trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            if !trusted { SystemPermission.accessibility.openSettings() }
        }
        PermissionMonitor.shared.refresh()
        if prefs.enabled { waitForTrust() }
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

    /// An active tap (not only a listener): the accept keys must not reach the app as an ordinary Tab.
    private func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue | 1 << CGEventType.leftMouseDown.rawValue
            | 1 << CGEventType.rightMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: autocompleteTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
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
        // What is on the clipboard now was copied before autocomplete started: not recent.
        clipboardSeen = (NSPasteboard.general.changeCount, .distantPast)
        return true
    }

    private func stop() {
        dismiss()
        commitSample()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
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
        fieldContext = nil
        windowText = nil
        upcoming = nil
        commitSample()
        dismiss()
        scheduleWarm(after: 0.3)
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

    /// Turned on but not working: no access, no model, or the model failed. Shown in the notch and as a badge in Settings.
    var needsAttention: Bool {
        guard prefs.enabled else { return false }
        switch state {
        case .noAccess, .noModel, .failed: return true
        default: return false
        }
    }

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
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .leftMouseDown, .rightMouseDown:
            if type == .leftMouseDown, case .emoji(let picker) = proposal,
               let index = overlay.cardValue(at: NSEvent.mouseLocation, key: Self.emojiIndexKey), picker.choices.indices.contains(index) {
                take(index, from: picker)
                swallowMouseUp = true
                return true
            }
            dismiss()
            return false
        case .leftMouseUp:
            if swallowMouseUp { swallowMouseUp = false; return true }
            scheduleSelectionCheck()
            // Perhaps another field: read its context into the model before the first key.
            scheduleWarm(after: 0.3)
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
                if !commandLike, completion.suggestion.consume(typed: key.characters) {
                    completion.anchor += key.characters
                    if completion.suggestion.isEmpty {
                        // Typed to its end: the next suggestion follows as if it was taken.
                        self.proposal = nil
                        overlay.hide()
                        followUp(after: completion.anchor)
                        return false
                    }
                    self.proposal = .completion(completion)
                    // Move the ghost past the new letter right away; settle() puts it exactly where the app drew it.
                    overlay.advance(over: key.characters, remaining: completion.suggestion.remaining)
                    settle()
                    return false
                }
            case .replacement(let delete, let insert, let word):
                if acceptWord || acceptAll {
                    dismiss()
                    AutocompleteTyper.replace(last: delete, with: insert)
                    store.recordAccepted(insert, first: true, app: bundleID)
                    scheduleRefresh()
                    return true
                }
                // Escape: the word is meant this way. Not offered again (it would come back with every letter of the next word).
                if plainEscape { ignoredTypos.insert(word.lowercased()) }
            case .emoji(var picker):
                if plainEscape { dismiss(); return true }
                if key.modifiers == 0, let step = emojiStep(key.code) {
                    picker.selected = min(max(picker.selected + step, 0), picker.choices.count - 1)
                    self.proposal = .emoji(picker)
                    showEmojiPicker(picker)
                    return true
                }
                // Return too, once a name is typed: ":D" and Return still sends the message.
                if acceptWord || acceptAll || (key.code == kVK_Return && key.modifiers == 0 && picker.query.count >= 2) {
                    take(picker.selected, from: picker)
                    return true
                }
                // 1 to 9: the emoji with that number in the row with the selection. Shift is allowed: some layouts need it for digits.
                if !commandLike, !key.flags.contains(.maskAlternate), let number = Int(key.characters), (1...Self.emojiColumns).contains(number) {
                    let index = picker.selected / Self.emojiColumns * Self.emojiColumns + number - 1
                    if picker.choices.indices.contains(index) { take(index, from: picker) }
                    return true
                }
                // Typing on in the name, or taking a letter back: filter right away, without reading the field again.
                if !commandLike, let query = emojiQuery(picker.query, after: key) {
                    readToken += 1
                    refreshWork?.cancel()
                    let choices = CompletionEmojiCatalog.choices(for: query, recent: store.recentEmoji, limit: Self.emojiColumns * 4)
                    if choices.isEmpty {
                        dismiss()
                    } else {
                        picker.query = query
                        picker.choices = choices
                        picker.selected = 0
                        self.proposal = .emoji(picker)
                        showEmojiPicker(picker)
                    }
                    return false
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
        // Perhaps a message was sent: once new messages are on screen, read the new context before the next one is typed.
        if key.code == kVK_Return { scheduleWarm(after: 0.8) }
        return false
    }

    /// Types `text`. What is left of the suggestion stays: the word lands where its ghost was, so the overlay only moves once
    /// the app has caught up, without a flicker or a new model call.
    private func accept(_ raw: String, leaving rest: Completion) {
        var text = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled ? CompletionTypography.smartQuotes(raw, after: rest.anchor.last) : raw
        var ahead = rest.suggestion.isEmpty ? writtenAhead(after: rest.anchor + text, from: rest) : nil
        // The model ends the sentence right after the last word: its period comes along with the same key, not with another.
        if prefs.attachedPunctuation, var next = ahead, let mark = next.takeAttachedPunctuation() {
            text += mark
            ahead = next.isEmpty ? nil : next
        }
        AutocompleteTyper.type(text)
        store.recordAccepted(text, first: rest.fresh, app: frontApp?.bundleIdentifier)
        if rest.suggestion.isEmpty {
            let anchor = rest.anchor + text
            if continueAtOnce(after: anchor, typed: text, from: rest, ahead: ahead) { return }
            proposal = nil
            overlay.hide()
            followUp(after: anchor)
        } else {
            var rest = rest
            rest.anchor += text
            rest.fresh = false
            proposal = .completion(rest)
            overlay.advance(over: text, remaining: rest.suggestion.remaining)
            settle()
        }
    }

    /// After the last word of a suggestion is taken: when the next one is already written (see `upcoming`), show it right
    /// away, moved past the word just typed as if the app had drawn it already. `settle()` then puts it where the app shows
    /// the cursor. No pause, no read first, no model call: Tab, Tab, Tab goes on as fast as you press it.
    private func continueAtOnce(after anchor: String, typed: String, from previous: Completion, ahead: CompletionSuggestion?) -> Bool {
        guard let suggestion = ahead, overlay.advance(over: typed, remaining: suggestion.remaining) else { return false }
        var next = previous
        next.suggestion = suggestion
        next.anchor = anchor
        next.fresh = true
        next.snapshot.before = anchor
        upcoming = nil
        proposal = .completion(next)
        store.recordShown()
        writeAhead(for: next)
        settle()
        return true
    }

    /// The suggestion written ahead (see `upcoming`) for the text `anchor`, when the model is done with it.
    private func writtenAhead(after anchor: String, from previous: Completion) -> CompletionSuggestion? {
        guard let ahead = upcoming, ahead.done, ahead.app == previous.app.bundleIdentifier, ahead.before == anchor, let result = ahead.result else { return nil }
        return CompletionSuggestion.make(raw: result.text, before: anchor, after: previous.after, maxWords: previous.maxWords,
                                         truncated: result.truncated, unfinished: result.unfinished)
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
        // Reads still under way are for text that is no longer there.
        readToken += 1
        refreshWork?.cancel()
        warmWork?.cancel()
        completer?.cancel()
        upcoming = nil
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

    /// Reads the prompt for the focused field into the model ahead of the next key. The context before the typed text
    /// (memory, screen, samples) is most of the prompt; when it is new (another app or field, a message sent, the window's
    /// text just read) the model would otherwise read all of it on that key, which on a larger model takes seconds.
    private func scheduleWarm(after seconds: TimeInterval) {
        warmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.warmFocusedField() } }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func warmFocusedField() {
        guard completer != nil, let app = frontApp, isActive(in: app) else { return }
        read(in: app) { [weak self] snapshot in
            guard let self, let snapshot, !snapshot.hasSelection, self.prefs.isEnabled(onSite: snapshot.site), let completer = self.completer else { return }
            completer.warm(prompt: self.prompt(for: snapshot, in: app))
        }
    }

    /// - Parameter continuing: right after a whole suggestion was taken (see `CompletionOptions.continuing()`).
    private func propose(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication, continuing: Bool = false) {
        lastSite = snapshot.site
        guard prefs.isEnabled(onSite: snapshot.site) else { return }
        record(snapshot, app: app.bundleIdentifier)
        if snapshot.hasSelection { return }
        if !prefs.smallFields, let field = snapshot.fieldFrame, field.width > 0, field.width < 150 { return }

        if prefs.emoji, let anchor = snapshot.caret ?? snapshot.fieldFrame, let query = CompletionEmojiCatalog.query(in: snapshot.before) {
            let choices = CompletionEmojiCatalog.choices(for: query, recent: store.recentEmoji, limit: Self.emojiColumns * 4)
            // A colon with no emoji by that name is just a colon.
            guard !choices.isEmpty else { return }
            let picker = EmojiPicker(query: query, choices: choices, anchor: anchor)
            proposal = .emoji(picker)
            showEmojiPicker(picker)
            return
        }

        // Text Nook just typed itself is the model's own spelling: no need to check it.
        if prefs.typos, !continuing, let fix = AutocompleteTypos.fix(for: snapshot.before, known: typoKnown),
           prefs.showTypoFixes || !fix.typedOn {
            // Never build a suggestion on a likely typo.
            if prefs.showTypoFixes, let caret = snapshot.caret {
                proposal = .replacement(delete: fix.deleteCount, insert: fix.replacement, word: fix.original)
                let text = NSMutableAttributedString(string: fix.original, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor,
                ])
                text.append(NSAttributedString(string: "  " + fix.corrected, attributes: [.foregroundColor: NSColor.labelColor]))
                overlay.showCard(card(text), below: caret)
            }
            return
        }

        requestCompletion(for: snapshot, in: app, continuing: continuing)
    }

    private func requestCompletion(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication, continuing: Bool) {
        let bundleID = app.bundleIdentifier
        let midLine = prefs.midLine(inApp: bundleID)
        let policy = CompletionPolicy(midLine: midLine)
        guard let model = activeModel, policy.shouldComplete(before: snapshot.before, after: snapshot.after, hasSelection: snapshot.hasSelection) else { return }
        var maxWords = prefs.maxWords
        if prefs.shorterOnBattery, onBattery { maxWords = min(maxWords, 4) }
        var options = CompletionOptions(maxWords: maxWords, eagerness: prefs.eagerness)
        if continuing { options = options.continuing() }
        options.heal = Self.midWord(snapshot.before)
        let prompt = self.prompt(for: snapshot, in: app)
        let token = readToken
        let after = midLine ? snapshot.after : ""
        // Written ahead while the last suggestion was on screen: no need to ask the model again.
        let ahead = upcoming.flatMap { $0.app == bundleID && $0.before == snapshot.before ? $0.task : nil }
        upcoming = nil
        Task {
            if let ahead, let result = await ahead.value {
                guard token == readToken else { return }
                present(result.text, truncated: result.truncated, unfinished: result.unfinished, token: token, snapshot: snapshot,
                        after: after, maxWords: maxWords, app: app)
                return
            }
            guard let completer = await loadedCompleter(for: model), token == readToken else { return }
            // The whole suggestion at once, never word by word as the model writes it.
            let result = await completer.complete(prompt: prompt, options: options, partial: nil)
            scheduleUnload()
            if let result {
                present(result.text, truncated: result.truncated, unfinished: result.unfinished, token: token, snapshot: snapshot,
                        after: after, maxWords: maxWords, app: app)
            }
        }
    }

    /// Shows a suggestion for the text of `snapshot`, unless the user has done something since (`token`) or something else is
    /// on screen.
    private func present(_ text: String, truncated: Bool, unfinished: Bool = false, token: Int, snapshot: AutocompleteFieldSnapshot,
                         after: String, maxWords: Int, app: NSRunningApplication) {
        guard token == readToken, alternatives == nil, proposal == nil,
              let suggestion = CompletionSuggestion.make(raw: text, before: snapshot.before, after: after, maxWords: maxWords, truncated: truncated,
                                                         unfinished: unfinished) else { return }
        let completion = Completion(suggestion: suggestion, anchor: snapshot.before, snapshot: snapshot, app: app, after: after, maxWords: maxWords)
        proposal = .completion(completion)
        show(suggestion, for: snapshot, in: app)
        store.recordShown()
        writeAhead(for: completion)
    }

    /// Starts writing how the text goes on after the whole suggestion on screen (see `upcoming`).
    private func writeAhead(for completion: Completion) {
        guard let model = activeModel else { return }
        let rest = completion.suggestion.remaining
        let typed = NSSpellChecker.isAutomaticQuoteSubstitutionEnabled ? CompletionTypography.smartQuotes(rest, after: completion.anchor.last) : rest
        var next = completion.snapshot
        next.before = completion.anchor + typed
        let before = next.before
        let prompt = self.prompt(for: next, in: completion.app)
        var options = CompletionOptions(maxWords: completion.maxWords, eagerness: prefs.eagerness).continuing()
        options.heal = Self.midWord(before)
        let task = Task { () -> CompletionResult? in
            guard let completer = await loadedCompleter(for: model) else { return nil }
            let result = await completer.complete(prompt: prompt, options: options, partial: nil)
            if upcoming?.before == before {
                upcoming?.done = true
                upcoming?.result = result
            }
            return result
        }
        upcoming = Upcoming(app: completion.app.bundleIdentifier, before: before, task: task)
    }

    /// The cursor stands right after a letter or digit: the model has to finish that word first (see `CompletionOptions.heal`).
    private static func midWord(_ before: String) -> Bool {
        guard let last = before.last else { return false }
        return last.isLetter || last.isNumber
    }

    /// After the last word of a suggestion is taken: waits until the app shows it, then suggests again right away, without
    /// the pause after a key (the next suggestion is usually written already, see `upcoming`).
    private func followUp(after anchor: String, attempt: Int = 0) {
        if attempt == 0 { readToken += 1 }
        guard let app = frontApp, isActive(in: app) else { return }
        read(in: app) { [weak self] snapshot in
            guard let self else { return }
            if let snapshot, snapshot.before == anchor {
                self.propose(for: snapshot, in: app, continuing: true)
            } else if attempt < self.settleAttempts {
                let token = self.readToken
                DispatchQueue.main.asyncAfter(deadline: .now() + self.settleInterval) {
                    MainActor.assumeIsolated { if token == self.readToken { self.followUp(after: anchor, attempt: attempt + 1) } }
                }
            } else {
                self.scheduleRefresh()
            }
        }
    }

    /// Builds the prompt. Everything around the typed text (instructions, memory, screen, clipboard, writing samples, where you
    /// write) is taken once per field and then kept: it comes before the text in the prompt, so if it changed with every key
    /// the model would have to read the whole prompt again. With it fixed, a key costs only the last few tokens.
    private func prompt(for snapshot: AutocompleteFieldSnapshot, in app: NSRunningApplication) -> CompletionPrompt {
        let bundleID = app.bundleIdentifier
        let key = CompletionFieldKey.make(app: bundleID, site: snapshot.site, placeholder: snapshot.placeholder, windowTitle: snapshot.windowTitle)
        // A message was sent (the field emptied), or the context is a few minutes old: new messages may have come in, so read
        // the screen again. Rarely enough that the prompt cache still pays off.
        let length = snapshot.before.count + snapshot.after.count
        let sent = fieldLength.map { $0.key == key && $0.length >= 8 && length < $0.length / 2 } ?? false
        fieldLength = (key, length)
        if let saved = fieldContext, saved.key == key, sent || Date().timeIntervalSince(saved.made) > Self.contextSeconds {
            fieldContext = nil
            if windowText?.key == key { windowText = nil }
        }
        if let saved = fieldContext, saved.key == key {
            var input = saved.context
            input.before = snapshot.before
            return builder.build(input)
        }
        var input = CompletionContext(before: "")
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
            let own = snapshot.before + snapshot.after
            // The pane around the field first (the conversation, the mail being answered): it is what the text replies to.
            // Nook's own screen reading of the whole window fills in until that is read.
            if let read = windowText, read.key == key, let text = read.text, !text.isEmpty {
                input.screenText = text
            } else {
                if windowText?.key != key { readWindow(key: key, app: app, own: own) }
                let seen = screenText(bundleID).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                if let seen {
                    input.screenText = CompletionScreenText.prose(CompletionPrivacy.sanitize(own.isEmpty ? seen : seen.replacingOccurrences(of: own, with: "")))
                }
            }
        }
        if prefs.clipboardContext {
            let board = NSPasteboard.general
            if clipboardSeen?.count != board.changeCount { clipboardSeen = (board.changeCount, Date()) }
            let recent = clipboardSeen.map { Date().timeIntervalSince($0.date) < Self.clipboardSeconds } ?? false
            // Password managers mark secrets as concealed: leave those alone.
            let concealed = board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false
            if recent, !concealed { input.clipboard = board.string(forType: .string).map(CompletionPrivacy.sanitize) }
        }
        if prefs.learn, prefs.personalStrength > 0, let bundleID { input.samples = store.samples.relevant(for: bundleID, limit: 2) }
        fieldContext = (key, Date(), input)
        input.before = snapshot.before
        return builder.build(input)
    }

    /// Reads the text around the field being written in (the pane it sits in, see `AppTextReader.textAroundFocus`), off the
    /// main thread, once per field context. The prompt takes it from the next key on; until then suggestions go on without
    /// it, so a slow app never holds up the first one.
    private func readWindow(key: String, app: NSRunningApplication, own: String) {
        guard windowText?.key != key else { return }
        windowText = (key, nil)
        let pid = app.processIdentifier
        let limit = builder.maxContextLength * 3
        windowQueue.async {
            let text = AppTextReader.textAroundFocus(pid: pid, limit: limit).map { text in
                CompletionScreenText.prose(CompletionPrivacy.sanitize(own.isEmpty ? text : text.replacingOccurrences(of: own, with: "")))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.windowText?.key == key, let text else { return }
                    self.windowText = (key, text)
                    // Build the field's context again with the window in it, and read it into the model now rather than on
                    // the next key.
                    if self.fieldContext?.key == key {
                        self.fieldContext = nil
                        self.scheduleWarm(after: 0)
                    }
                }
            }
        }
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
        if let caret = snapshot.caret, prefs.inlineGhost {
            let font = GhostOverlay.font(name: snapshot.fontName, size: snapshot.fontSize, caretHeight: caret.height, scale: rule.fontScale)
            let shown = overlay.showGhost(suggestion.remaining, at: caret, font: font, limit: snapshot.fieldFrame.map { $0.maxX - 4 },
                                          verticalOffset: rule.verticalOffset)
            if !shown.isEmpty {
                // Only what is on screen can be taken: Tab must never type words you did not see.
                if shown.count < suggestion.remaining.count, case .completion(var completion) = proposal {
                    completion.suggestion = CompletionSuggestion(shown)
                    proposal = .completion(completion)
                }
                return
            }
        }
        // No room in the line, no cursor position, or the card style chosen: a card under the cursor or the field.
        if let anchor = snapshot.caret ?? snapshot.fieldFrame {
            overlay.showCard(card(suggestion.remaining.trimmingCharacters(in: .whitespaces)), below: anchor)
        } else {
            proposal = nil
            overlay.hide()
        }
    }

    /// Types the emoji at `index` in place of the colon and the name.
    private func take(_ index: Int, from picker: EmojiPicker) {
        let emoji = picker.choices[index]
        let rendered = CompletionEmojiCatalog.render(emoji, skinTone: prefs.skinTone)
        dismiss()
        AutocompleteTyper.replace(last: picker.query.count + 1, with: rendered)
        store.recordAccepted(rendered, first: true, app: frontApp?.bundleIdentifier)
        store.recordEmoji(emoji.character)
        scheduleRefresh()
    }

    /// The picker's name after `key`: one more letter, or one fewer for Delete. Nil when the key ends the name (a space,
    /// punctuation, or Delete right after the colon, which takes the colon away).
    private func emojiQuery(_ query: String, after key: Key) -> String? {
        if key.code == kVK_Delete { return query.isEmpty || key.modifiers != 0 ? nil : String(query.dropLast()) }
        guard key.characters.count == 1, let character = key.characters.first, character.isASCII,
              character.isLetter || character.isNumber || "_+-".contains(character), query.count < 30 else { return nil }
        return query + key.characters
    }

    /// How far an arrow key moves through the picker: one to the side, a row up or down. Nil for other keys.
    private func emojiStep(_ code: Int) -> Int? {
        switch code {
        case kVK_LeftArrow: return -1
        case kVK_RightArrow: return 1
        case kVK_UpArrow: return -Self.emojiColumns
        case kVK_DownArrow: return Self.emojiColumns
        default: return nil
        }
    }

    /// The picker as a card under the cursor: rows of emoji with the selected one marked, the numbers 1 to 9 over the row
    /// with the selection, and the selected one's name below.
    private func showEmojiPicker(_ picker: EmojiPicker) {
        let text = NSMutableAttributedString()
        let big = NSFont.systemFont(ofSize: 20)
        let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let row = picker.selected / Self.emojiColumns
        for (index, emoji) in picker.choices.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: index % Self.emojiColumns == 0 ? "\n" : "  ", attributes: [.font: big])) }
            // Every emoji has its number; only the row with the selection shows it, so the rows stay in line.
            let numbered = index / Self.emojiColumns == row
            text.append(NSAttributedString(string: "\(index % Self.emojiColumns + 1)", attributes: [
                .font: small, .foregroundColor: numbered ? NSColor.secondaryLabelColor : NSColor.clear, Self.emojiIndexKey: index,
            ]))
            var attributes: [NSAttributedString.Key: Any] = [.font: big, Self.emojiIndexKey: index]
            if index == picker.selected { attributes[.backgroundColor] = NSColor.controlAccentColor.withAlphaComponent(0.35) }
            text.append(NSAttributedString(string: CompletionEmojiCatalog.render(emoji, skinTone: prefs.skinTone), attributes: attributes))
        }
        let name = picker.choices[picker.selected].shortcodes[0]
        text.append(NSAttributedString(string: "\n:\(name):", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        text.append(NSAttributedString(string: "   1–9  ←→↑↓  " + prefs.acceptWord.label + " ↩", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        overlay.showCard(text, below: picker.anchor)
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
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.showAlternatives(selectionOnly: true) } }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Words to pick by number: for the selected word, or, without a selection, instead of the word Nook would suggest next.
    /// - Parameter selectionOnly: only for a selected word (shown by itself after selecting, not after every click).
    private func showAlternatives(selectionOnly: Bool = false) {
        guard let app = frontApp, isActive(in: app) else { return }
        var suggested = ""
        if case .completion(let completion) = proposal { suggested = completion.suggestion.nextChunk().trimmingCharacters(in: .whitespaces) }
        if !selectionOnly { dismiss() }
        read(in: app) { [weak self] snapshot in
            guard let self, let snapshot, !selectionOnly || snapshot.hasSelection else { return }
            if selectionOnly { self.dismiss() }
            self.showAlternatives(for: snapshot, in: app, suggested: suggested)
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
        let vocabulary = prefs.learn ? store.samples.vocabulary() : [:]
        // Words the user writes again and again are theirs (names, jargon, slang), not typos.
        knownWords = Set(vocabulary.keys.map { $0.lowercased() })
        completer?.setPersonalization(words: vocabulary, strength: prefs.learn ? prefs.personalStrength : 0)
    }

    // MARK: The model

    private func loadedCompleter(for model: CompletionSource) async -> (any CompletionEngine)? {
        let identity = model.identity
        if let completer, completer.identity == identity { return completer }
        if let loading, loading.identity == identity { return await loading.task.value }
        state = .loading
        let task = Task { () -> (any CompletionEngine)? in
            do {
                let loaded: any CompletionEngine
                switch model {
                case .gguf(let file): loaded = try await LlamaCompleter.load(path: file.url.path)
                // The brain's model is loaded by the brain itself, on the first suggestion; nothing to wait for here.
                case .brain(let id, _): loaded = BrainCompleter(modelID: id)
                }
                // Another model was chosen while this one loaded: let it go.
                guard activeModel?.identity == identity else { return nil }
                completer = loaded
                applyPersonalization()
                state = .ready
                return loaded
            } catch {
                if activeModel?.identity == identity { state = .failed(error.localizedDescription) }
                return nil
            }
        }
        loading = (identity, task)
        let result = await task.value
        if loading?.identity == identity { loading = nil }
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
