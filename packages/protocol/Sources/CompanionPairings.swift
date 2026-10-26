import Foundation

// The Macs this phone is paired with (docs/COMPANION.md, "Several Macs"). One of them is active: the phone keeps its live
// connection to that one, and checks the others now and then for what waits there. Each Mac keeps its own key, routes,
// outbox and features, stored under its id (the public identifier of its key, `PairedDevice.identifier`), so a message
// written to one Mac can never go to another.

struct PairedMac: Codable, Equatable, Identifiable, Sendable {
    /// `PairedDevice.identifier(forKey:)` of the pairing key: the same id the Mac knows this phone by.
    var id: String
    var name: String
    var host: String
    var port: UInt16
    /// The pairing key, base64url (kept in the Keychain with the rest of this list).
    var key: String
    var routes: [CompanionRoute]
    var pairedAt: Double

    init(link: PairingLink, routes: [CompanionRoute]? = nil, pairedAt: Date = Date()) {
        id = PairedDevice.identifier(forKey: link.key)
        name = link.macName
        host = link.host
        port = link.port
        key = Base64URL.encode(link.key)
        self.routes = routes ?? CompanionRoutes.initial(from: link)
        self.pairedAt = pairedAt.timeIntervalSince1970
    }

    /// The pairing as a link (host, port, key and name), as the connection code needs it; nil when the stored key is broken.
    var link: PairingLink? {
        guard let data = Base64URL.decode(key), data.count == PairingLink.keyLength else { return nil }
        return PairingLink(host: host, port: port, key: data, macName: name)
    }
}

struct CompanionPairings: Codable, Equatable, Sendable {
    private(set) var macs: [PairedMac] = []
    private(set) var activeID: String?
    /// The Mac a phone was paired with before it could pair with several (`migrate`): its outbox and features keep their
    /// old names (`storageName`).
    private(set) var legacyID: String?

    /// Most Macs one phone keeps.
    static let maxMacs = 8

    init() {}

    var active: PairedMac? { macs.first { $0.id == activeID } ?? macs.first }
    var others: [PairedMac] { macs.filter { $0.id != active?.id } }
    var isEmpty: Bool { macs.isEmpty }

    func contains(_ id: String) -> Bool { macs.contains { $0.id == id } }

    /// Adds a Mac that was just paired and makes it the active one. Pairing the same Mac again (the same key) replaces it;
    /// a Mac that paired anew (a new key, the same name and address) replaces the old pairing too, since that key is dead.
    /// False when the list is full.
    @discardableResult
    mutating func add(_ link: PairingLink, routes: [CompanionRoute]? = nil, now: Date = Date()) -> Bool {
        let mac = PairedMac(link: link, routes: routes, pairedAt: now)
        let replaced = macs.firstIndex { $0.id == mac.id || ($0.name == mac.name && $0.host.lowercased() == mac.host.lowercased()) }
        if let replaced {
            macs[replaced] = mac
        } else {
            guard macs.count < Self.maxMacs else { return false }
            macs.append(mac)
        }
        activeID = mac.id
        return true
    }

    mutating func remove(_ id: String) {
        macs.removeAll { $0.id == id }
        if activeID == id { activeID = macs.first?.id }
    }

    /// False for an id that is not paired.
    @discardableResult
    mutating func select(_ id: String) -> Bool {
        guard macs.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    mutating func setRoutes(_ routes: [CompanionRoute], for id: String) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        macs[index].routes = routes
    }

    mutating func rename(_ id: String, to name: String) {
        guard let index = macs.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        macs[index].name = name
    }

    /// The list from what a phone stored before it could pair with several Macs: the one pairing and its routes.
    static func migrate(legacy link: PairingLink?, routes: [CompanionRoute]?, now: Date = Date()) -> CompanionPairings {
        var pairings = CompanionPairings()
        if let link {
            pairings.add(link, routes: routes, now: now)
            pairings.legacyID = PairedDevice.identifier(forKey: link.key)
        }
        return pairings
    }

    /// A file or defaults key for something kept per Mac (`companion-outbox.json` → `companion-outbox-<id>.json`,
    /// `companion.features` → `companion.features.<id>`). The Mac a phone was paired with before it could pair with
    /// several keeps the old name, so nothing written before the update is lost.
    static func storageName(_ base: String, mac id: String, legacyID: String?) -> String {
        if id == legacyID { return base }
        guard base.hasSuffix(".json") else { return base + "." + id }
        return String(base.dropLast(5)) + "-" + id + ".json"
    }
}
