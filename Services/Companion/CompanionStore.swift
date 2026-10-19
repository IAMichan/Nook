import Foundation
import Security

/// The phones paired with this Mac. Keys are in the Keychain, the list (names, dates) in UserDefaults; a key that is not in
/// the Keychain any more cannot open a message, so removing a device is deleting its key.
@MainActor
final class CompanionStore: ObservableObject {
    static let shared = CompanionStore()

    @Published private(set) var devices: [PairedDevice] = []
    /// A pairing in progress: the key shown to the phone and when it stops being valid.
    @Published private(set) var pending: (key: Data, until: Date)?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    private static let listKey = "companion.devices.v1"
    private static let enabledKey = "companion.enabled"
    static let portKey = "companion.port"

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = list.filter { Self.key(for: $0.id) != nil }
        }
    }

    private static func account(_ id: String) -> String { "companion.key." + id }

    static func key(for id: String) -> Data? {
        guard let text = Keychain.read(account(id)), let data = Base64URL.decode(text), data.count == PairingLink.keyLength else { return nil }
        return data
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: Self.listKey) }
    }

    /// Opens a pairing window and returns the key to show. The key becomes a device only when the phone proves it holds it.
    func beginPairing(now: Date = Date()) -> Data {
        var bytes = [UInt8](repeating: 0, count: PairingLink.keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = status == errSecSuccess ? Data(bytes) : Data((0..<PairingLink.keyLength).map { _ in UInt8.random(in: 0...255) })
        pending = (key, now.addingTimeInterval(CompanionConstants.pairingWindow))
        return key
    }

    func cancelPairing() { pending = nil }

    /// The pairing key, while its window is open.
    func activePending(now: Date = Date()) -> Data? {
        guard let pending, pending.until > now else { self.pending = nil; return nil }
        return pending.key
    }

    /// The phone proved the pending key: it is a device from now on.
    func completePairing(name: String, now: Date = Date()) -> PairedDevice? {
        guard let key = activePending(now: now) else { return nil }
        let id = PairedDevice.identifier(forKey: key)
        guard Keychain.write(Base64URL.encode(key), account: Self.account(id)) == errSecSuccess else { return nil }
        let clean = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(60))
        let device = PairedDevice(id: id, name: clean.isEmpty ? "iPhone" : clean, pairedAt: now, lastSeen: now)
        devices.removeAll { $0.id == id }
        devices.append(device)
        pending = nil
        save()
        return device
    }

    func touch(_ id: String, now: Date = Date()) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        // Not on every request: a minute is fine for "last seen".
        if let last = devices[index].lastSeen, now.timeIntervalSince(last) < 60 { return }
        devices[index].lastSeen = now
        save()
    }

    func remove(_ id: String) {
        Keychain.write("", account: Self.account(id))
        devices.removeAll { $0.id == id }
        save()
    }

    func removeAll() { for device in devices { Keychain.write("", account: Self.account(device.id)) }; devices = []; save() }
}
