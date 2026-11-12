import Foundation

/// The API keys of the brain's AI providers (Settings › Brain), one path for all of them: each provider's key lives in
/// its own account of `SecretStore`, is read and saved the same way, and says the same things in Settings (saved,
/// masked, looks valid). Claude's key used to have a path of its own; it now goes through here like every other.
///
/// The accounts keep the names they had, so no saved key is lost: Claude's key stays in `anthropic-api-key` (its name
/// from before the providers had their own accounts), every other provider's in `<provider>-api-key`.
/// Foundation-only, with the store passed in, so tests never touch the Keychain.
struct ProviderKeys {
    /// Reads an account's secret (nil: none), and writes one (an empty value removes it); returns an `OSStatus`.
    var read: (String) -> String?
    var write: (String, String) -> Int32

    /// Accounts whose name is not `<provider>-api-key`: kept as they were, so the key saved there is still found.
    static let keptAccounts = ["claude": "anthropic-api-key"]

    /// The account of a provider (`AIProvider.rawValue`).
    static func account(provider: String) -> String {
        keptAccounts[provider] ?? "\(provider)-api-key"
    }

    func key(provider: String) -> String? {
        guard let key = read(Self.account(provider: provider)), !key.isEmpty else { return nil }
        return key
    }

    func hasKey(provider: String) -> Bool { key(provider: provider) != nil }

    /// Saves a pasted key (trimmed of whitespace and quotes; empty removes it). Returns the `OSStatus` of the write.
    @discardableResult
    func save(_ key: String, provider: String) -> Int32 {
        write(Self.clean(key), Self.account(provider: provider))
    }

    /// Pasting often brings whitespace, a newline, or quotes along.
    static func clean(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
    }

    /// Only the ends of a key, to recognize which one is saved; nil for a key too short to show any of it.
    static func masked(_ key: String?) -> String? {
        guard let key, key.count > 12 else { return nil }
        return "\(key.prefix(7))…\(key.suffix(4))"
    }

    /// Whether a key looks like the provider's own: it starts with the prefix the provider gives its keys (nil: any
    /// key) and has no spaces.
    static func looksValid(_ key: String, prefix: String?) -> Bool {
        let clean = clean(key)
        guard !clean.isEmpty, !clean.contains(" ") else { return false }
        return prefix.map { clean.hasPrefix($0) } ?? true
    }
}
