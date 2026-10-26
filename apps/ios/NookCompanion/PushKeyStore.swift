import Foundation
import Security

/// The push keys (`RelayPush.pushKey`) of the paired Macs, for the Notification Service Extension (NookNotifications),
/// which opens notifications sent through the relay. One Keychain item in the app group's access group, by device id
/// (what a sealed push names in "d"): readable after the first unlock, so a push that arrives while the phone is locked
/// can still be opened. It holds only push keys, derived one way from the pairing keys; the pairing itself stays in
/// `PairingStore`, readable only while unlocked.
enum PushKeyStore {
    /// The app group both targets carry (project.yml); on iOS an app group is also a Keychain access group.
    static let accessGroup = "group.nl.imdigital.nook.companion"
    private static let service = "nl.imdigital.nook.companion.push"
    private static let account = "push-keys"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup]
    }

    /// Device id → push key.
    static func all() -> [String: Data] {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return stored.compactMapValues { Data(base64Encoded: $0) }
    }

    static func key(forDevice id: String) -> Data? { all()[id] }

    static func set(_ key: Data?, forDevice id: String) {
        var keys = all()
        keys[id] = key
        save(keys)
    }

    private static func save(_ keys: [String: Data]) {
        SecItemDelete(base as CFDictionary)
        guard !keys.isEmpty, let data = try? JSONEncoder().encode(keys.mapValues { $0.base64EncodedString() }) else { return }
        var attributes = base
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
