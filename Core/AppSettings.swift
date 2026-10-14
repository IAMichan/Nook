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

    /// Kan Nook nadenken? Met een lokaal model is een API-sleutel niet nodig.
    var brainReady: Bool { useLocal ? !localModel.isEmpty : hasAPIKey }
    /// Naam van wat er nu denkt, voor in meldingen.
    var activeModelName: String { useLocal ? (localModel.split(separator: "/").last.map(String.init) ?? localModel) : model }

    private var cachedKey: String?
    var apiKey: String? { cachedKey }

    private init() {
        model = UserDefaults.standard.string(forKey: "model") ?? "claude-sonnet-5-5"
        autoWatch = UserDefaults.standard.bool(forKey: "autoWatch")
        useLocal = UserDefaults.standard.bool(forKey: "useLocal")
        localModel = UserDefaults.standard.string(forKey: "localModel") ?? ""
        let key = Keychain.read(Self.keyAccount)
        cachedKey = key
        hasAPIKey = !(key ?? "").isEmpty
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
