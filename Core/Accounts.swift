import Foundation

/// One account at a service, such as "GitHub · Werk". Holds no secrets: those stay in the Keychain under `key(_:)`.
///
/// The first account of a service has the service's own id ("github"), so its Keychain names are exactly the ones Nook
/// used before accounts existed (`connector.github.token`): existing keys become the primary account without being copied.
struct ServiceAccount: Codable, Identifiable, Equatable, Hashable {
    /// "github" for the primary account, "github.werk" for others.
    var id: String
    var service: String
    var label: String
    /// Who the service says this is ("@michan", "michan@…"). Filled in by the connector, never typed by the user.
    var identity: String?

    var isPrimary: Bool { id == service }

    /// Keychain account name for one credential field of this account ("token" → "connector.github.werk.token").
    func key(_ field: String) -> String { "connector.\(id).\(field)" }

    /// "GitHub · Werk", or just "GitHub" for a single, unnamed primary account.
    func title(service title: String) -> String {
        label.isEmpty ? title : "\(title) · \(label)"
    }
}

/// The accounts per service, shared by Settings (managing them), connectors (using them) and chats (limiting them).
/// Stored in UserDefaults as a list; the primary account of a service always exists, even when nothing is stored.
final class AccountRegistry: @unchecked Sendable {
    static let shared = AccountRegistry()

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var stored: [ServiceAccount]
    /// Called after every change, on the thread that made it.
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard, storageKey: String = "serviceAccounts") {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey) {
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("nook-\(storageKey).json")
            stored = SafeStorage.decode(LossyArray<ServiceAccount>.self, data: data, original: backup, skipped: { $0.skipped })
                .value?.elements ?? []
        } else {
            stored = []
        }
    }

    /// All accounts of a service, primary first.
    func accounts(for service: String) -> [ServiceAccount] {
        lock.lock()
        defer { lock.unlock() }
        let own = stored.filter { $0.service == service }
        let primary = own.first { $0.isPrimary } ?? ServiceAccount(id: service, service: service, label: "")
        return [primary] + own.filter { !$0.isPrimary }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func account(id: String) -> ServiceAccount? {
        let service = id.split(separator: ".").first.map(String.init) ?? id
        return accounts(for: service).first { $0.id == id }
    }

    /// Adds another account to a service. The id is derived from the label and unique within the service.
    @discardableResult
    func add(service: String, label: String) -> ServiceAccount {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let base = Self.slug(clean.isEmpty ? "account" : clean)
        var id = "\(service).\(base)"
        var counter = 2
        while stored.contains(where: { $0.id == id }) {
            id = "\(service).\(base)\(counter)"
            counter += 1
        }
        let account = ServiceAccount(id: id, service: service, label: clean.isEmpty ? "Account \(counter - 1)" : clean)
        stored.append(account)
        lock.unlock()
        save()
        return account
    }

    func rename(_ id: String, to label: String) {
        update(id) { $0.label = label.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setIdentity(_ identity: String?, for id: String) {
        guard account(id: id)?.identity != identity else { return }
        update(id) { $0.identity = identity }
    }

    /// Removes an account from the list. The caller removes its secrets from the Keychain. The primary account cannot be
    /// removed (only emptied): it holds the keys of earlier versions.
    func remove(_ id: String) {
        lock.lock()
        stored.removeAll { $0.id == id && !$0.isPrimary }
        lock.unlock()
        save()
    }

    /// Finds the account a user or model referred to: by id, label or identity, case-insensitive, among `candidates`.
    static func match(_ reference: String, in candidates: [ServiceAccount]) -> ServiceAccount? {
        let needle = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !needle.isEmpty else { return nil }
        return candidates.first { $0.id.lowercased() == needle }
            ?? candidates.first { $0.label.lowercased() == needle }
            ?? candidates.first { ($0.identity ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@")) == needle }
    }

    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "account" : String(collapsed.prefix(24))
    }

    private func update(_ id: String, _ change: (inout ServiceAccount) -> Void) {
        lock.lock()
        if let index = stored.firstIndex(where: { $0.id == id }) {
            change(&stored[index])
        } else if let primary = id.split(separator: ".").count == 1 ? id : nil {
            // The primary account is only stored once something about it changes.
            var account = ServiceAccount(id: primary, service: primary, label: "")
            change(&account)
            stored.append(account)
        }
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        let snapshot = stored
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: storageKey) }
        onChange?()
    }
}
