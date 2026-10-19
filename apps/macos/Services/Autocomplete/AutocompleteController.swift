import AppKit
import Carbon.HIToolbox

/// Autocomplete anywhere: while you type in another app, a local model suggests how the sentence could go on, drawn next to
/// the cursor. The accept key (Tab) types it for you; any other key sends it away.
///
/// The text before the cursor is read through the Accessibility API, handed to a model on this Mac and forgotten again: nothing
/// is stored or sent anywhere. Password fields are never read. The model is a GGUF file, by default the one Cotypist downloaded.
@MainActor
final class AutocompleteController: ObservableObject {
    static let shared = AutocompleteController()

    enum State: Equatable {
        case off, noAccess, noModel, loading, ready
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// The models of Cotypist found on this Mac.
    @Published private(set) var candidates: [CompletionModelFile] = []
    /// The model that is used now.
    @Published private(set) var activeModel: CompletionModelFile?
    @Published private(set) var trusted = AXIsProcessTrusted()

    /// Apps where a suggestion would get in the way or must never be read: terminals, password managers and Nook itself.
    static let excludedApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "nl.imdigital.nook"
    ]

    private let store = AutocompleteStore.shared
    private let overlay = GhostOverlay()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var appObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var suggestion: String?
    private var pending: Task<Void, Never>?
    private var cancel: CompletionCancel?
    private var completer: LlamaCompleter?
    private var loading: Task<LlamaCompleter?, Never>?
    private var idleTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?

    /// Wait this long after the last key before asking the model, so it works on the finished word and not on every letter.
    private static let debounce: UInt64 = 250_000_000
    /// The model is dropped from memory after this many seconds without typing.
    private static let idleSeconds: UInt64 = 300

    private init() {}

    /// At launch, and whenever autocompletion is turned on or off or its model changes.
    func refresh() {
        removeTap()
        dismiss()
        trustTask?.cancel()
        trustTask = nil
        trusted = AXIsProcessTrusted()
        guard store.enabled else {
            unload()
            state = .off
            return
        }
        Task {
            let found = await Task.detached(priority: .utility) { CompletionModelLocator.cotypistModels() }.value
            candidates = found
            let model = CompletionModelLocator.resolve(storedPath: store.modelPath, candidates: found)
            if model?.url.path != activeModel?.url.path { unload() }
            activeModel = model
            guard store.enabled else { return }
            guard trusted else { state = .noAccess; waitForTrust(); return }
            guard installTap() else { state = .noAccess; waitForTrust(); return }
            state = model == nil ? .noModel : .ready
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

    /// Until macOS trusts Nook there is no key watcher: check every 2 s and start once it does.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.store.enabled else { return }
                if AXIsProcessTrusted() { self.refresh(); return }
            }
        }
    }

    // MARK: The keys

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<AutocompleteController>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated { controller.handle(type: type, event: event) }
    }

    /// An active tap (not only a listener) is needed to keep the accept key from reaching the app as an ordinary Tab.
    private func installTap() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                           callback: Self.tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        appObserver = nil
        mouseMonitor = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }
        guard type == .keyDown, store.enabled else { return passThrough }
        // The key events Nook sends itself when it types a suggestion.
        if event.getIntegerValueField(.eventSourceUserData) == AutocompleteTyper.marker { return passThrough }

        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let others = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if suggestion != nil, store.acceptKey.matches(keyCode: code, optionDown: flags.contains(.maskAlternate), othersDown: others) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.accept() } }
            return nil
        }
        dismiss()
        if code == UInt16(kVK_Escape) || others { return passThrough }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Self.excludedApps.contains(front) { return passThrough }
        schedule()
        return passThrough
    }

    // MARK: Suggesting

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.generate()
        }
    }

    private func dismiss() {
        pending?.cancel()
        cancel?.cancel()
        suggestion = nil
        overlay.hide()
    }

    private func accept() {
        guard let text = suggestion else { return }
        dismiss()
        AutocompleteTyper.type(text)
        schedule()
    }

    private func generate() async {
        guard store.enabled, let model = activeModel, let app = NSWorkspace.shared.frontmostApplication,
              !Self.excludedApps.contains(app.bundleIdentifier ?? "") else { return }
        guard let snapshot = AutocompleteField.read(), CompletionText.shouldSuggest(before: snapshot.before, after: snapshot.after) else { return }
        guard let completer = await loadedCompleter(for: model), !Task.isCancelled else { return }
        idleTask?.cancel()

        cancel?.cancel()
        let token = CompletionCancel()
        cancel = token
        let raw: String
        do {
            raw = try await completer.complete(prompt: CompletionText.prompt(before: snapshot.before), maxTokens: 24, cancel: token)
        } catch {
            Log.brain.error("autocomplete failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        scheduleUnload()
        // Typing carried on while the model was working: this suggestion is for text that is no longer there.
        guard !Task.isCancelled, !token.isCancelled,
              let now = AutocompleteField.read(), now.before == snapshot.before, now.after == snapshot.after,
              let text = CompletionText.clean(raw, before: snapshot.before) else { return }
        suggestion = text
        overlay.show(text, key: store.acceptKey.symbol, at: now.caret)
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
        completer = nil
    }
}
