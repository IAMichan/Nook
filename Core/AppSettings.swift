import Foundation
import Security

/// De API-sleutel staat in de Keychain, nooit in een bestand.
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

    /// Taal van Nooks antwoorden: een code uit `languages`, of "auto" (de taal van je vraag).
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    static let languages: [(code: String, name: String)] = [
        ("nl", "Nederlands"), ("en", "Engels"), ("de", "Duits"), ("fr", "Frans"), ("es", "Spaans"),
        ("auto", "Taal van mijn vraag")
    ]

    /// Zin voor in de prompt, bijvoorbeeld "Antwoord altijd in het Engels."
    var languageInstruction: String {
        if language == "auto" { return "Antwoord in de taal waarin de gebruiker schrijft." }
        let name = Self.languages.first { $0.code == language }?.name ?? "Nederlands"
        return "Antwoord altijd in het \(name), ook als de gegevens of tools in een andere taal zijn."
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    /// Nook kijkt zelf af en toe mee met het scherm. Standaard uit.
    @Published var autoWatch: Bool {
        didSet { UserDefaults.standard.set(autoWatch, forKey: "autoWatch") }
    }
    /// Gebruik een gratis lokaal model (ingebouwd, MLX) in plaats van de Claude API.
    @Published var useLocal: Bool {
        didSet { UserDefaults.standard.set(useLocal, forKey: "useLocal") }
    }
    @Published var localModel: String {
        didSet { UserDefaults.standard.set(localModel, forKey: "localModel") }
    }
    @Published private(set) var hasAPIKey: Bool

    /// Op welk scherm Nook staat: "auto" (scherm met notch, anders het hoofdscherm), "main", "mouse"
    /// (volgt je muis) of de naam van een scherm.
    @Published var screenChoice: String {
        didSet { UserDefaults.standard.set(screenChoice, forKey: "screenChoice") }
    }
    /// In rust alleen de notch zelf: Nook verschijnt pas als er iets is of als je erop wijst.
    @Published var hideWhenIdle: Bool {
        didSet { UserDefaults.standard.set(hideWhenIdle, forKey: "hideWhenIdle") }
    }
    /// Een kort geluid als een agent op je wacht of klaar is.
    @Published var sounds: Bool {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    /// Antwoorden voorlezen als je met je stem iets vroeg.
    @Published var speakAnswers: Bool {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "speakAnswers") }
    }
    /// Luisteren naar "Hé Nook" (alleen op je Mac).
    @Published var wakeWord: Bool {
        didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord") }
    }

    /// Met welke aanbieder Nook denkt als hij niet het ingebouwde model gebruikt.
    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            refreshProviderKey()
        }
    }
    /// Model per aanbieder (voor Claude is dat `model`).
    @Published var providerModels: [String: String] {
        didSet { UserDefaults.standard.set(providerModels, forKey: "providerModels") }
    }
    @Published private(set) var hasProviderKey = false

    /// Mag Claude op het web zoeken (Anthropic's eigen zoektool)? Alleen bij Claude.
    @Published var webSearch: Bool {
        didSet { UserDefaults.standard.set(webSearch, forKey: "webSearch") }
    }
    /// Houd de tekst van al je vensters op al je schermen live bij (lokaal), zodat elke vraag die context heeft.
    @Published var liveScreen: Bool {
        didSet { UserDefaults.standard.set(liveScreen, forKey: "liveScreen") }
    }
    /// Stuur bij elke vraag mee wat er op je schermen staat (niet alleen als je "dit" of "hier" zegt).
    @Published var screenWithEveryQuestion: Bool {
        didSet { UserDefaults.standard.set(screenWithEveryQuestion, forKey: "screenWithEveryQuestion") }
    }
    /// De welkomststappen zijn doorlopen.
    @Published var onboardingDone: Bool {
        didSet { UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone") }
    }

    /// Kan Nook nadenken? Met een lokaal model of een server op je Mac is een API-sleutel niet nodig.
    var brainReady: Bool {
        if useLocal { return !localModel.isEmpty }
        switch provider {
        case .claude: return hasAPIKey
        case .claudeCode: return ClaudeCodeBrain.executable != nil
        case .ollama, .lmstudio: return !activeProviderModel.isEmpty || provider == .lmstudio
        default: return hasProviderKey && !activeProviderModel.isEmpty
        }
    }

    /// Het model dat bij de gekozen aanbieder hoort.
    var activeProviderModel: String {
        provider == .claude ? model : (providerModels[provider.rawValue] ?? provider.defaultModel)
    }

    func setProviderModel(_ id: String) {
        if provider == .claude { model = id } else { providerModels[provider.rawValue] = id }
    }

    /// Naam van wat er nu denkt, voor in meldingen.
    var activeModelName: String {
        if useLocal { return localModel.split(separator: "/").last.map(String.init) ?? localModel }
        let name = activeProviderModel
        return provider == .claude ? name : "\(provider.title) · \(name.isEmpty ? "eerste model" : name)"
    }

    /// Sleutel van de gekozen (niet-Claude) aanbieder.
    var providerKey: String? {
        provider == .claude ? apiKey : Keychain.read(provider.keyAccount)
    }

    private func refreshProviderKey() {
        hasProviderKey = provider == .claude ? hasAPIKey : !(Keychain.read(provider.keyAccount) ?? "").isEmpty
    }

    /// Bewaart de sleutel voor een andere aanbieder dan Claude.
    @discardableResult
    func saveProviderKey(_ key: String, for provider: AIProvider) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        let status = Keychain.write(trimmed, account: provider.keyAccount)
        refreshProviderKey()
        objectWillChange.send()
        return status == errSecSuccess ? nil : ((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain-fout \(status)")
    }

    func hasKey(for provider: AIProvider) -> Bool {
        provider == .claude ? hasAPIKey : !(Keychain.read(provider.keyAccount) ?? "").isEmpty
    }

    private var cachedKey: String?
    var apiKey: String? { cachedKey }

    private init() {
        // Haiku is veel sneller dan Sonnet en genoeg voor Nooks taken. Eenmalig overzetten als je nog op de oude standaard zat.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "modelDefaultFast") {
            defaults.set(true, forKey: "modelDefaultFast")
            if defaults.string(forKey: "model") == "claude-sonnet-5-5" { defaults.removeObject(forKey: "model") }
        }
        model = defaults.string(forKey: "model") ?? "claude-haiku-5-5"
        language = defaults.string(forKey: "language") ?? "nl"
        autoWatch = UserDefaults.standard.bool(forKey: "autoWatch")
        useLocal = UserDefaults.standard.bool(forKey: "useLocal")
        localModel = UserDefaults.standard.string(forKey: "localModel") ?? ""
        screenChoice = defaults.string(forKey: "screenChoice") ?? "auto"
        hideWhenIdle = defaults.bool(forKey: "hideWhenIdle")
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        speakAnswers = defaults.bool(forKey: "speakAnswers")
        wakeWord = defaults.bool(forKey: "wakeWord")
        provider = AIProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .claude
        providerModels = (defaults.dictionary(forKey: "providerModels") as? [String: String]) ?? [:]
        webSearch = defaults.object(forKey: "webSearch") as? Bool ?? true
        liveScreen = defaults.object(forKey: "liveScreen") as? Bool ?? true
        screenWithEveryQuestion = defaults.object(forKey: "screenWithEveryQuestion") as? Bool ?? true
        // Wie Nook al gebruikte (sleutel of model aanwezig), hoeft de welkomststappen niet meer te zien.
        let key = Keychain.read(Self.keyAccount)
        cachedKey = key
        hasAPIKey = !(key ?? "").isEmpty
        // Lokale waarden: `self` mag hier nog niet gelezen worden, want nog niet alles is ingesteld.
        onboardingDone = defaults.bool(forKey: "onboardingDone") || !(key ?? "").isEmpty
            || !(defaults.string(forKey: "localModel") ?? "").isEmpty
        refreshProviderKey()
    }

    /// Bewaart de sleutel. De sleutel werkt in elk geval deze sessie; `keychainError` is gevuld als de Keychain weigerde.
    @discardableResult
    func saveAPIKey(_ key: String) -> (keychainError: String?, looksValid: Bool) {
        // Plakken geeft vaak spaties, regeleinden of aanhalingstekens mee.
        let trimmed = key
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        let status = Keychain.write(trimmed, account: Self.keyAccount)
        cachedKey = trimmed.isEmpty ? nil : trimmed
        hasAPIKey = !trimmed.isEmpty
        refreshProviderKey()
        let error: String? = status == errSecSuccess ? nil
            : ((SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain-fout \(status)")
        return (error, trimmed.hasPrefix("sk-ant-") && !trimmed.contains(" "))
    }

    /// Alleen het einde van de sleutel, om te controleren welke er is opgeslagen.
    var maskedKey: String? {
        guard let key = cachedKey, key.count > 12 else { return nil }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }
}
