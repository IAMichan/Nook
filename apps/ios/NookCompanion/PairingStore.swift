import Foundation
import Security

/// The Macs this phone is paired with (`CompanionPairings`: where each Mac is, its key and its routes), in the Keychain:
/// this device only, not synced, not in backups. A phone paired before it could pair with several Macs had one pairing
/// and its routes under two other accounts; the first load turns them into the list and removes them.
enum PairingStore {
    private static let service = "nl.imdigital.nook.companion"
    private static let pairingsAccount = "pairings"
    // Before several Macs: one pairing and its routes.
    private static let legacyAccount = "pairing"
    private static let legacyRoutesAccount = "routes"

    private struct Legacy: Codable {
        var host: String
        var port: UInt16
        var key: String
        var macName: String
    }

    static func load() -> CompanionPairings {
        if let data = read(pairingsAccount), let pairings = try? JSONDecoder().decode(CompanionPairings.self, from: data) {
            return pairings
        }
        let legacy = read(legacyAccount).flatMap { try? JSONDecoder().decode(Legacy.self, from: $0) }
        let link = legacy.flatMap { stored in
            Base64URL.decode(stored.key).map { PairingLink(host: stored.host, port: stored.port, key: $0, macName: stored.macName) }
        }
        let routes = read(legacyRoutesAccount).flatMap { try? JSONDecoder().decode([CompanionRoute].self, from: $0) }
        let pairings = CompanionPairings.migrate(legacy: link, routes: routes?.isEmpty == false ? routes : nil)
        if link != nil, save(pairings) {
            delete(legacyAccount)
            delete(legacyRoutesAccount)
        }
        return pairings
    }

    @discardableResult
    static func save(_ pairings: CompanionPairings) -> Bool {
        guard let data = try? JSONEncoder().encode(pairings) else { return false }
        delete(pairingsAccount)
        // The Notification Service Extension opens relay pushes with the push keys derived from these pairings.
        PushKeyStore.sync(pairingKeys: pairings.macs.compactMap { $0.link?.key })
        if pairings.isEmpty { return true }
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: pairingsAccount, kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func read(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func delete(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
