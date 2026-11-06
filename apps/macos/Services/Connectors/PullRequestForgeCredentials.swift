import Foundation

/// Personal tokens per forge host, in the Keychain, for the forges other than GitHub and GitLab, which have their own.
/// Sent only to that host over https. Bitbucket and Azure DevOps use Basic auth: there the token is `user:token`
/// (for Azure DevOps an empty user, `:token`, works).
enum ForgeCredentials {
    private static let hostsKey = "forge.hosts"

    private static func account(_ host: String) -> String { "forge.token." + host.lowercased() }

    static func token(host: String) -> String? { CloudHelp.secret(account(host)) }

    static var hosts: [String] {
        (UserDefaults.standard.stringArray(forKey: hostsKey) ?? []).filter { token(host: $0) != nil }
    }

    @discardableResult
    static func save(host: String, token: String) -> Bool {
        guard let host = GitLabCredentials.normalize(host) else { return false }
        let clean = ConnectorField.clean(token)
        guard !clean.isEmpty, Keychain.write(clean, account: account(host)) == errSecSuccess else { return false }
        var list = UserDefaults.standard.stringArray(forKey: hostsKey) ?? []
        if !list.contains(host) { list.append(host) }
        UserDefaults.standard.set(list, forKey: hostsKey)
        return true
    }

    static func remove(host: String) {
        Keychain.write("", account: account(host))
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: hostsKey) ?? []).filter { $0 != host.lowercased() }, forKey: hostsKey)
    }
}

extension ForgeEnvironment {
    /// The app's tokens and session for the forge adapters.
    static func install() {
        token = { ForgeCredentials.token(host: $0) }
        gitLabToken = { GitLabCredentials.token(host: $0) }
        session = ConnectorHTTP.patientSession
    }
}
