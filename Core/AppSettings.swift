import Foundation
import Security

/// The API key is stored in the Keychain, never in a file.
enum Keychain {
    static let service = "nl.imdigital.nook"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> OSStatus {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil)
    }
}

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
        ("nl", "Nederlands"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
        ("auto", "Taal van mijn vraag")
    ]

    /// Prompt sentence, e.g. "Always respond in English."
    var languageInstruction: String {
        if language == "auto" { return "Respond in the language the user writes in." }
        let name = Self.languages.first { $0.code == language }?.name ?? "Nederlands"
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
    @Published var hideWhenIdle: Bool {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "hideWhenIdle") }
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
    /// Keep window text across all displays updated live (locally), providing context for queries.
    @Published var liveScreen: Bool {
        didSet { UserDefaults.standard.set(liveScreen, forKey: "liveScreen") }
    }
    /// Include display contents with every query (not only when saying "this" or "here").
    @Published var screenWithEveryQuestion: Bool {
        didSet { UserDefaults.standard.set(screenWithEveryQuestion, forKey: "screenWithEveryQuestion") }
    }
    /// Onboarding flow completed.
    @Published var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
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
        language = defaults.string(forKey: "language") ?? "nl"
        autoWatch = UserDefaults.standard.bool(forKey: "autoWatch")
        autoRunSafe = defaults.bool(forKey: "autoRunSafe")
        useLocal = UserDefaults.standard.bool(forKey: "useLocal")
        localModel = UserDefaults.standard.string(forKey: "localModel") ?? ""
        screenChoice = defaults.string(forKey: "screenChoice") ?? "auto"
        placement = defaults.string(forKey: "placement") ?? "notch"
        hideWhenIdle = defaults.bool(forKey: "hideWhenIdle")
        notchOnAllScreens = defaults.bool(forKey: "notchOnAllScreens")
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        speakAnswers = defaults.bool(forKey: "speakAnswers")
        wakeWord = defaults.bool(forKey: "wakeWord")
        provider = AIProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .claude
        providerModels = (defaults.dictionary(forKey: "providerModels") as? [String: String]) ?? [:]
        webSearch = defaults.object(forKey: "webSearch") as? Bool ?? true
        liveScreen = defaults.object(forKey: "liveScreen") as? Bool ?? true
        screenWithEveryQuestion = defaults.object(forKey: "screenWithEveryQuestion") as? Bool ?? true
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
