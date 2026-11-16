import CryptoKit
import Foundation
import Security

/// The phone's own signing key per paired Mac (`CompanionDeviceKey`, docs/COMPANION.md, "Device key"): made in the Secure
/// Enclave where the phone has one (a P-256 key that cannot be read out, only used), else in software, and kept in the
/// Keychain for this device only. Once a Mac took its public half (`CompanionOp.bindKey`), every request to that Mac is
/// signed with it (`CompanionChannel.frame`).
///
/// Thread-safe: requests are framed on the connection's queue.
enum DeviceKeyStore {
    private static let service = "nl.imdigital.nook.companion.devicekey"
    private static let boundKey = "nook.companion.deviceKeyBound"
    private static let lock = NSLock()
    /// Keys read once per launch: the Keychain is not read for every ping.
    nonisolated(unsafe) private static var cache: [String: Signer] = [:]

    /// One way to sign: a Secure Enclave key or, where there is none (the simulator), a software key.
    private enum Signer {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .enclave(let key): return key.publicKey
            case .software(let key): return key.publicKey
            }
        }

        func sign(_ data: Data) -> Data? {
            switch self {
            case .enclave(let key): return try? key.signature(for: data).rawRepresentation
            case .software(let key): return try? key.signature(for: data).rawRepresentation
            }
        }
    }

    // MARK: Bound to a Mac

    /// Whether the Mac with pairing id `id` holds this phone's key: then every request to it is signed.
    static func isBound(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: boundKey) ?? []).contains(id)
    }

    static func markBound(_ id: String) {
        var bound = UserDefaults.standard.stringArray(forKey: boundKey) ?? []
        guard !bound.contains(id) else { return }
        bound.append(id)
        UserDefaults.standard.set(bound, forKey: boundKey)
    }

    /// Unpaired from that Mac: its key and the mark go, so a new pairing starts with a new key.
    static func forget(_ id: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: boundKey) ?? []).filter { $0 != id }, forKey: boundKey)
        lock.lock()
        cache[id] = nil
        lock.unlock()
        SecItemDelete(query(id) as CFDictionary)
    }

    // MARK: The key

    /// The public half (X9.63) of the key for the Mac with pairing id `id`, made now when there is none yet.
    static func publicKey(for id: String) -> Data? {
        signer(for: id, create: true)?.publicKey.x963Representation
    }

    /// `envelope` signed for the Mac with pairing id `id` (`CompanionSeal` field `g`) when that Mac holds the key; the
    /// envelope as it is otherwise. Nil when it should be signed and cannot be (the key is gone): the Mac would refuse it.
    static func signIfBound(_ envelope: Data, id: String) -> Data? {
        guard isBound(id) else { return envelope }
        guard let signer = signer(for: id, create: false), let bytes = CompanionSeal.signedBytes(envelope),
              let signature = signer.sign(bytes) else { return nil }
        return CompanionSeal.attach(signature: signature, to: envelope)
    }

    private static func signer(for id: String, create: Bool) -> Signer? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        if let stored = read(id) {
            cache[id] = stored
            return stored
        }
        guard create, let made = make(id) else { return nil }
        cache[id] = made
        return made
    }

    // MARK: Keychain

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    /// Stored as one byte that says which kind (1: Secure Enclave, 2: software) and the key's own data: for the Secure
    /// Enclave a handle only that chip can use, never the key itself.
    private static func read(_ id: String) -> Signer? {
        var lookup = query(id)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let kind = data.first else { return nil }
        let body = data.dropFirst()
        switch kind {
        case 1: return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: body)).map(Signer.enclave)
        case 2: return (try? P256.Signing.PrivateKey(rawRepresentation: body)).map(Signer.software)
        default: return nil
        }
    }

    private static func make(_ id: String) -> Signer? {
        let signer: Signer
        let stored: Data
        if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            signer = .enclave(key)
            stored = Data([1]) + key.dataRepresentation
        } else {
            let key = P256.Signing.PrivateKey()
            signer = .software(key)
            stored = Data([2]) + key.rawRepresentation
        }
        SecItemDelete(query(id) as CFDictionary)
        var attributes = query(id)
        attributes[kSecValueData as String] = stored
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { return nil }
        return signer
    }
}
