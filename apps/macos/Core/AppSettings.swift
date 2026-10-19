import Foundation
import NaturalLanguage
import Security

/// The one place secrets are read from and written to the Keychain (API keys, tokens, webhook URLs).
///
/// All secrets live together in one Keychain item (the vault, a JSON dictionary) that is read once per launch and then
/// kept in memory. macOS asks for Keychain access per item and per build of the app, so one item means at most one
/// prompt instead of one for every key, token and paired device. Older separate items move into the vault on first use.
/// Accounts other programs read (see `isStandalone`) stay items of their own, and are cached too.
///
/// Writing updates the existing item in place and only adds one when there is none, so a failed write can no longer
/// leave the old key deleted and the new one missing. Values are trimmed first (pasted keys often carry a newline).
/// The data-protection keychain is deliberately not used: it needs a signed build with a keychain access group,
/// and Nook is also run unsigned from source.
enum SecretStore {
    static let service = "nl.imdigital.nook"
    private static let vaultAccount = "vault"

    /// Accounts the `security` tool reads from a terminal command (the Claude agent's API key), so they cannot move
    /// into the vault.
    static func isStandalone(_ account: String) -> Bool { account.hasPrefix("agent.apikey.") }

    private static let lock = NSLock()
    /// The vault's contents once loaded; nil until then.
    private nonisolated(unsafe) static var vault: [String: String]?
    /// Why the vault could not be read this launch (access denied, unreadable): reads return nil and writes fail,
    /// so a vault that is merely locked away is never overwritten with only the newest secret.
    private nonisolated(unsafe) static var vaultFailure: OSStatus?
    /// Standalone secrets already read this launch; "" means there is none.
    private nonisolated(unsafe) static var standalone: [String: String] = [:]

    /// The secret, trimmed; nil when missing or empty.
    static func read(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if isStandalone(account) {
            if let cached = standalone[account] { return cached.isEmpty ? nil : cached }
            let (data, status) = item(account)
            let value = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Only remember a definite answer; a denied prompt is asked again next time.
            if status == errSecSuccess || status == errSecItemNotFound { standalone[account] = value }
            return value.isEmpty ? nil : value
        }
        guard let vault = loadVault(), let value = vault[account], !value.isEmpty else { return nil }
        return value
    }

    /// Saves the secret; an empty value removes it.
    @discardableResult
    static func write(_ value: String, account: String) -> OSStatus {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return remove(account) }
        lock.lock(); defer { lock.unlock() }
        if isStandalone(account) {
            let status = store(Data(cleaned.utf8), account: account)
            if status == errSecSuccess { standalone[account] = cleaned }
            return status
        }
        vaultFailure = nil  // Saving is something you chose to do, so a vault that was denied earlier is asked for again.
        guard var updated = loadVault() else { return vaultFailure ?? errSecInteractionNotAllowed }
        if updated[account] == cleaned { return errSecSuccess }
        updated[account] = cleaned
        return saveVault(updated)
    }

    @discardableResult
    static func remove(_ account: String) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        if isStandalone(account) {
            let status = delete(account)
            if status == errSecSuccess { standalone[account] = "" }
            return status
        }
        vaultFailure = nil  // Saving is something you chose to do, so a vault that was denied earlier is asked for again.
        guard var updated = loadVault() else { return vaultFailure ?? errSecInteractionNotAllowed }
        // A leftover separate item (one migration could not read) goes too, so it cannot come back later.
        _ = delete(account)
        guard updated.removeValue(forKey: account) != nil else { return errSecSuccess }
        return saveVault(updated)
    }

    // MARK: - Vault

    /// The vault, read from the Keychain the first time (moving older separate items into it); nil when it cannot be
    /// read. Callers hold `lock`.
    private static func loadVault() -> [String: String]? {
        if let vault { return vault }
        if vaultFailure != nil { return nil }
        let (data, status) = item(vaultAccount)
        var contents: [String: String] = [:]
        switch status {
        case errSecSuccess:
            guard let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                vaultFailure = errSecDecode
                return nil
            }
            contents = decoded
        case errSecItemNotFound:
            break
        default:
            vaultFailure = status
            return nil
        }
        // Separate items from earlier versions move in. Listing them reads attributes only, so this asks for nothing
        // once they are gone.
        var moved: [String] = []
        for account in legacyAccounts() where account != vaultAccount && !isStandalone(account) {
            let (itemData, itemStatus) = item(account)
            // An item that cannot be read now (access denied) stays where it is and is tried again next launch.
            guard itemStatus == errSecSuccess, let itemData, let text = String(data: itemData, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, contents[account] == nil { contents[account] = trimmed }
            moved.append(account)
        }
        if !moved.isEmpty {
            let saved = saveVault(contents)
            guard saved == errSecSuccess else {
                vaultFailure = saved
                return nil
            }
            for account in moved { _ = delete(account) }
        }
        vault = contents
        return contents
    }

    /// Writes the vault and, when that worked, keeps it as the in-memory copy.
    private static func saveVault(_ contents: [String: String]) -> OSStatus {
        guard let data = try? JSONEncoder().encode(contents) else { return errSecParam }
        let status = store(data, account: vaultAccount)
        if status == errSecSuccess { vault = contents }
        return status
    }

    // MARK: - Keychain items

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func item(_ account: String) -> (Data?, OSStatus) {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    /// Account names of every item under `service`. Only attributes are read, which never asks for access.
    private static func legacyAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func store(_ data: Data, account: String) -> OSStatus {
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    private static func delete(_ account: String) -> OSStatus {
        let status = SecItemDelete(base(account) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// The name the rest of the app already uses.
typealias Keychain = SecretStore

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let keyAccount = "anthropic-api-key"

    /// Language of the app interface (Nederlands, English, Deutsch).
    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            I18n.shared.language = appLanguage
        }
    }

    /// Language for Nook's responses: a code from `languages`, or "auto" (the language of your question).
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("nl", "Nederlands"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
        ("auto", "Language of my question")
    ]

    /// The language to answer this request in: the chosen language, or with "auto" the language the request is written in.
    func answerLanguage(for text: String) -> NLLanguage? {
        if language != "auto" { return NLLanguage(rawValue: language) }
        return Self.detectLanguage(text)
    }

    /// The language a text is written in, when it is clear enough to tell.
    static func detectLanguage(_ text: String) -> NLLanguage? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }), best.value > 0.5 else { return nil }
        return best.key
    }

    /// Prompt sentence for one request, naming the language explicitly: small models drift to English otherwise.
    func languageInstruction(for text: String) -> String {
        guard language == "auto", let detected = Self.detectLanguage(text),
              let name = Locale(identifier: "en").localizedString(forLanguageCode: detected.rawValue) else { return languageInstruction }
        return "Always respond in \(name), the language of the request, even if the data or tools are in a different language."
    }

    /// Prompt sentence, e.g. "Always respond in English."
    var languageInstruction: String {
        if language == "auto" { return "Respond in the language the user writes in." }
        let name = Self.languages.first { $0.code == language }?.name ?? "English"
        return "Always respond in \(name), even if the data or tools are in a different language."
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    /// Proactive assistance: Nook watches along while you work and offers suggestions ("Shall I do this for you?"). Off by default.
    @Published var autoWatch: Bool {
        didSet { UserDefaults.standard.set(autoWatch, forKey: "autoWatch") }
    }
    /// Immediately perform minor user requests (music, volume, opening an app, reminders, or open loops)
    /// without pressing Run first. Proactive suggestions always ask first. Off by default.
    @Published var autoRunSafe: Bool {
        didSet { UserDefaults.standard.set(autoRunSafe, forKey: "autoRunSafe") }
    }
    /// Use a free local model (built-in, MLX) instead of the Claude API.
    @Published var useLocal: Bool {
        didSet { UserDefaults.standard.set(useLocal, forKey: "useLocal") }
    }
    @Published var localModel: String {
        didSet { UserDefaults.standard.set(localModel, forKey: "localModel") }
    }
    @Published private(set) var hasAPIKey: Bool

    /// Which display Nook is shown on: "auto" (display with notch, otherwise main display), "main", "mouse"
    /// (follows mouse) or display name.
    @Published var screenChoice: String {
        didSet { UserDefaults.standard.set(screenChoice, forKey: "screenChoice") }
    }
    /// Where Nook is placed: "notch" (fixed at the top notch) or "floating" (draggable floating panel).
    @Published var placement: String {
        didSet { UserDefaults.standard.set(placement, forKey: "placement") }
    }
    /// Position of the floating panel: offset from screen center (positive is right)
    /// and distance below menu bar. Saved when panel is released.
    var floatOffsetX: Double {
        get { UserDefaults.standard.double(forKey: "floatOffsetX") }
        set { UserDefaults.standard.set(newValue, forKey: "floatOffsetX") }
    }
    var floatOffsetY: Double {
        get { UserDefaults.standard.object(forKey: "floatOffsetY") as? Double ?? 8 }
        set { UserDefaults.standard.set(newValue, forKey: "floatOffsetY") }
    }
    /// Notch placement: show the notch on every connected screen, not just the chosen one.
    @Published var notchOnAllScreens: Bool {
        didSet { UserDefaults.standard.set(notchOnAllScreens, forKey: "notchOnAllScreens") }
    }
    /// When idle, only the notch itself: Nook appears when hovered or when activity occurs.
    /// Accent color of the whole app (Nook's orb, active tabs, chips, buttons), as 0xRRGGBB.
    @Published var accentHex: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(accentHex), forKey: "accentHex")
            NookTheme.accentHex = accentHex
        }
    }

    @Published var hideWhenIdle: Bool {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "hideWhenIdle") }
    }
    /// Larger panel (wider and taller) for chat and agents.
    @Published var panelLarge: Bool {
        didSet { UserDefaults.standard.set(panelLarge, forKey: "panelLarge") }
    }
    /// Play a short sound when an agent finishes or awaits input.
    @Published var sounds: Bool {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    /// Read responses aloud when asked by voice.
    @Published var speakAnswers: Bool {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "speakAnswers") }
    }
    /// Listen for "Hey Nook" wake word (local on Mac only).
    @Published var wakeWord: Bool {
        didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord") }
    }

    /// Provider Nook uses for reasoning when not using the built-in model.
    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            refreshProviderKey()
        }
    }
    /// Model per provider (for Claude, `model` is used).
    @Published var providerModels: [String: String] {
        didSet { UserDefaults.standard.set(providerModels, forKey: "providerModels") }
    }
    @Published private(set) var hasProviderKey = false

    /// Allow Claude to search the web (Anthropic native search tool). Claude only.
    @Published var webSearch: Bool {
        didSet { UserDefaults.standard.set(webSearch, forKey: "webSearch") }
    }
    /// Music tab: look up lyrics on lrclib.net (sends the title, artist, album and length of the playing track).
    @Published var onlineLyrics: Bool {
        didSet { UserDefaults.standard.set(onlineLyrics, forKey: "onlineLyrics") }
    }
    /// Keep window text across all displays updated live (locally), providing context for queries.
    @Published var liveScreen: Bool {
        didSet { UserDefaults.standard.set(liveScreen, forKey: "liveScreen") }
    }
    /// Include display contents with every query (not only when saying "this" or "here").
    @Published var screenWithEveryQuestion: Bool {
        didSet { UserDefaults.standard.set(screenWithEveryQuestion, forKey: "screenWithEveryQuestion") }
    }
    /// Sources only a brain on this Mac may read ("only on this Mac"). An external brain never gets their context,
    /// tools, earlier answers built from them or screen text.
    @Published var localOnlySources: Set<String> {
        didSet { UserDefaults.standard.set(localOnlySources.sorted(), forKey: "localOnlySources") }
    }
    /// Local quality: a narrow first step copies the evidence out of each document, and the answer is written from those
    /// quotes (slower, more accurate). Only for small brains.
    @Published var evidenceFirst: Bool {
        didSet { UserDefaults.standard.set(evidenceFirst, forKey: "evidenceFirst") }
    }
    /// Local quality: Nook checks the numbers, times, addresses and links in an answer against its sources and has a small
    /// brain write the answer again when one is in none of them.
    @Published var checkAnswers: Bool {
        didSet { UserDefaults.standard.set(checkAnswers, forKey: "checkAnswers") }
    }
    /// Memory: what Nook learned about the user goes along with every question (Settings › Memory).
    @Published var useMemory: Bool {
        didSet { UserDefaults.standard.set(useMemory, forKey: "useMemory") }
    }
    /// Memory: Nook learns by itself from corrections, conversations and how plans are changed and run. Without it, Nook
    /// only remembers what the user asks it to.
    @Published var learnFromChats: Bool {
        didSet { UserDefaults.standard.set(learnFromChats, forKey: "learnFromChats") }
    }
    /// Onboarding flow completed.
    @Published var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }

    /// The active brain as one value (see `BrainSelection`); setting it writes the stored settings it is made of.
    var selection: BrainSelection {
        get { .resolve(useLocal: useLocal, provider: provider, localModel: localModel, providerModel: activeProviderModel) }
        set {
            let stored = newValue.storedValues
            if stored.provider != provider { provider = stored.provider }
            if useLocal != stored.useLocal { useLocal = stored.useLocal }
            if newValue.runtime == .mlx { if localModel != newValue.model { localModel = newValue.model } } else if !newValue.model.isEmpty {
                setProviderModel(newValue.model)
            }
        }
    }

    /// Whether the brain runs on this Mac (built-in model, Ollama or LM Studio): no data leaves the Mac, no cost per token.
    var isLocalBrain: Bool { selection.isLocal }

    /// The sources the active brain may not see: the "only on this Mac" sources while an external brain answers, none
    /// when the brain runs on this Mac.
    var privateSources: Set<String> { isLocalBrain ? [] : localOnlySources }

    /// What the active model can handle: prompts, tools and rounds are sized to it.
    var brainProfile: ModelProfile {
        let memory = ModelAdvisor.Hardware.current.memoryGB
        if useLocal, localModel == AppleModel.id { return .apple }
        if useLocal { return (ModelAdvisor.catalog.first { $0.id == localModel }?.profile ?? .localSmall).roomier(memoryGB: memory) }
        if provider.isLocalServer { return ModelAdvisor.profile(forServerModel: activeProviderModel).roomier(memoryGB: memory) }
        return .cloud
    }

    /// Short label for the model chip: "Qwen 2.5 (7B)", "Ollama · qwen2.5:7b", "Claude · claude-haiku-5-5".
    var brainLabel: String {
        if useLocal {
            if localModel.isEmpty { return tr("brain.chip.noModel") }
            if localModel == AppleModel.id { return AppleModel.title }
            return ModelAdvisor.catalog.first { $0.id == localModel }?.title ?? activeModelName
        }
        let name = activeProviderModel.isEmpty ? tr("brain.chip.firstModel") : activeProviderModel
        return "\(provider.title.components(separatedBy: " (").first ?? provider.title) · \(name)"
    }

    /// Whether Nook can reason. Local models or local server backends do not require an API key.
    var brainReady: Bool {
        if useLocal { return !localModel.isEmpty }
        switch provider {
        case .claude: return hasAPIKey
        case .claudeCode: return ClaudeCodeBrain.executable != nil
        case .ollama, .lmstudio: return !activeProviderModel.isEmpty || provider == .lmstudio
        default: return hasProviderKey && !activeProviderModel.isEmpty
        }
    }

    /// Model selected for the active provider.
    var activeProviderModel: String {
        provider == .claude ? model : (providerModels[provider.rawValue] ?? provider.defaultModel)
    }

    func setProviderModel(_ id: String) {
        if provider == .claude { model = id } else { providerModels[provider.rawValue] = id }
    }

    /// Name of the current reasoning engine, for notifications.
    var activeModelName: String {
        if useLocal, localModel == AppleModel.id { return AppleModel.title }
        if useLocal { return localModel.split(separator: "/").last.map(String.init) ?? localModel }
        let name = activeProviderModel
        return provider == .claude ? name : "\(provider.title) · \(name.isEmpty ? "first model" : name)"
    }

    /// Key for the selected provider.
    var providerKey: String? {
        provider == .claude ? apiKey : Keychain.read(provider.keyAccount)
    }

    private func refreshProviderKey() {
        hasProviderKey = provider == .claude ? hasAPIKey : !(Keychain.read(provider.keyAccount) ?? "").isEmpty
    }

    /// Saves the key for a provider other than Claude.
    @discardableResult
    func saveProviderKey(_ key: String, for provider: AIProvider) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        let status = Keychain.write(trimmed, account: provider.keyAccount)
        refreshProviderKey()
        objectWillChange.send()
        return status == errSecSuccess ? nil : ((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
    }

    func hasKey(for provider: AIProvider) -> Bool {
        provider == .claude ? hasAPIKey : !(Keychain.read(provider.keyAccount) ?? "").isEmpty
    }

    private var cachedKey: String?
    var apiKey: String? { cachedKey }

    private init() {
        // Haiku is much faster than Sonnet and sufficient for Nook's tasks. One-time migration for users on the old default.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "modelDefaultFast") {
            defaults.set(true, forKey: "modelDefaultFast")
            if defaults.string(forKey: "model") == "claude-sonnet-5-5" { defaults.removeObject(forKey: "model") }
        }
        model = defaults.string(forKey: "model") ?? "claude-haiku-5-5"
        if let stored = defaults.string(forKey: "appLanguage"), let lang = AppLanguage(rawValue: stored) {
            appLanguage = lang
        } else {
            appLanguage = I18n.shared.language
        }
        language = defaults.string(forKey: "language") ?? "en"
        autoWatch = UserDefaults.standard.bool(forKey: "autoWatch")
        autoRunSafe = defaults.bool(forKey: "autoRunSafe")
        // Local is the default brain: a fresh install thinks on the Mac itself. Someone who already chose an external
        // AI (a key or a provider was set before this version) keeps that choice.
        useLocal = BrainSelection.initialUseLocal(
            stored: defaults.object(forKey: "useLocal") as? Bool, storedProvider: defaults.string(forKey: "provider"),
            hasAnthropicKey: !(Keychain.read(Self.keyAccount) ?? "").isEmpty)
        localModel = UserDefaults.standard.string(forKey: "localModel") ?? ""
        screenChoice = defaults.string(forKey: "screenChoice") ?? "auto"
        placement = defaults.string(forKey: "placement") ?? "notch"
        let storedAccent = (defaults.object(forKey: "accentHex") as? Int).map { UInt32(truncatingIfNeeded: $0) } ?? NookTheme.defaultAccentHex
        accentHex = storedAccent
        NookTheme.accentHex = storedAccent
        hideWhenIdle = defaults.bool(forKey: "hideWhenIdle")
        panelLarge = defaults.bool(forKey: "panelLarge")
        notchOnAllScreens = defaults.bool(forKey: "notchOnAllScreens")
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        speakAnswers = defaults.bool(forKey: "speakAnswers")
        wakeWord = defaults.bool(forKey: "wakeWord")
        provider = AIProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .claude
        providerModels = (defaults.dictionary(forKey: "providerModels") as? [String: String]) ?? [:]
        webSearch = defaults.object(forKey: "webSearch") as? Bool ?? true
        onlineLyrics = defaults.object(forKey: "onlineLyrics") as? Bool ?? true
        liveScreen = defaults.object(forKey: "liveScreen") as? Bool ?? true
        screenWithEveryQuestion = defaults.object(forKey: "screenWithEveryQuestion") as? Bool ?? true
        localOnlySources = Set(defaults.stringArray(forKey: "localOnlySources") ?? [])
        evidenceFirst = defaults.bool(forKey: "evidenceFirst")
        checkAnswers = defaults.object(forKey: "checkAnswers") as? Bool ?? true
        useMemory = defaults.object(forKey: "useMemory") as? Bool ?? true
        learnFromChats = defaults.object(forKey: "learnFromChats") as? Bool ?? true
        // Existing users (key or model present) do not need to repeat onboarding.
        let key = Keychain.read(Self.keyAccount)
        cachedKey = key
        hasAPIKey = !(key ?? "").isEmpty
        // Local values: `self` cannot be read yet, as initialization is in progress.
        onboardingDone = defaults.bool(forKey: "onboardingDone") || !(key ?? "").isEmpty
            || !(defaults.string(forKey: "localModel") ?? "").isEmpty
        refreshProviderKey()
    }

    /// Saves the key. Active for at least this session; `keychainError` is set if Keychain failed.
    @discardableResult
    func saveAPIKey(_ key: String) -> (keychainError: String?, looksValid: Bool) {
        // Pasting often includes whitespace, newlines, or quotes.
        let trimmed = key
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        let status = Keychain.write(trimmed, account: Self.keyAccount)
        cachedKey = trimmed.isEmpty ? nil : trimmed
        hasAPIKey = !trimmed.isEmpty
        refreshProviderKey()
        let error: String? = status == errSecSuccess ? nil
            : ((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)")
        return (error, trimmed.hasPrefix("sk-ant-") && !trimmed.contains(" "))
    }

    /// Only the tail of the key, to verify which key is saved.
    var maskedKey: String? {
        guard let key = cachedKey, key.count > 12 else { return nil }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }
}
