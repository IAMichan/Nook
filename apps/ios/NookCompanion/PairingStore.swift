import Foundation
import Security

/// The pairing (where the Mac is and the key) of this phone, in the Keychain: this device only, not synced, not in backups.
enum PairingStore {
    private static let service = "nl.imdigital.nook.companion"
    private static let account = "pairing"

    private struct Stored: Codable {
        var host: String
        var port: UInt16
        var key: String
        var macName: String
    }

    static func load() -> PairingLink? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data), let key = Base64URL.decode(stored.key) else { return nil }
        return PairingLink(host: stored.host, port: stored.port, key: key, macName: stored.macName)
    }

    @discardableResult
    static func save(_ link: PairingLink) -> Bool {
        clear()
        guard let data = try? JSONEncoder().encode(Stored(host: link.host, port: link.port, key: Base64URL.encode(link.key), macName: link.macName)) else { return false }
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let saved = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        // The Notification Service Extension opens relay pushes with the push key derived from it.
        if saved { PushKeyStore.remember(pairingKey: link.key) }
        return saved
    }

    static func clear() {
        if let link = load() { PushKeyStore.forget(pairingKey: link.key) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        clearRoutes()
    }

    // MARK: Routes

    /// The ways to reach the paired Mac (`CompanionRoutes`), next to the pairing; nil when none were saved yet (a phone
    /// paired before routes existed starts from the pairing's own address).
    private static let routesAccount = "routes"

    static func loadRoutes() -> [CompanionRoute]? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: routesAccount, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let routes = try? JSONDecoder().decode([CompanionRoute].self, from: data), !routes.isEmpty else { return nil }
        return routes
    }

    static func saveRoutes(_ routes: [CompanionRoute]) {
        clearRoutes()
        guard let data = try? JSONEncoder().encode(routes) else { return }
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: routesAccount, kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func clearRoutes() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: routesAccount]
        SecItemDelete(query as CFDictionary)
    }
}
