import Foundation

/// A sign-in saved in Nook's browser: the site, the user name and the password. Kept in Nook's Keychain vault
/// (`BrowserPasswords`), never in a file.
struct BrowserCredential: Codable, Equatable, Identifiable, Sendable {
    var site: String
    var username: String
    var password: String
    var lastUsed: Date

    var id: String { site + "\u{1F}" + username }
}

/// The saved sign-ins and the sites you said never to save for, with the rules for which sign-in belongs to which page.
/// Foundation only, so tests can use it.
struct BrowserPasswordBook: Codable, Equatable, Sendable {
    var credentials: [BrowserCredential] = []
    /// Sites where you chose "Never for this site".
    var neverSites: [String] = []

    /// The site a page's sign-in belongs to: its host without `www.`, lowercased. Nil for a page that is not on the web
    /// over https (a password typed over plain http is never saved or filled), except a server on this Mac.
    static func site(scheme: String, host: String) -> String? {
        let host = host.lowercased()
        guard !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost")
        guard scheme.lowercased() == "https" || (local && scheme.lowercased() == "http") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The sign-ins for a site, the one used last first.
    func credentials(for site: String) -> [BrowserCredential] {
        credentials.filter { $0.site == site }.sorted { $0.lastUsed > $1.lastUsed }
    }

    func isNever(_ site: String) -> Bool { neverSites.contains(site) }

    /// What to do with a sign-in just sent on a site: nothing (already saved like this, or a site you said never for),
    /// or ask whether to save it (new) or update it (the password changed).
    enum Offer: Equatable {
        case none
        case save
        case update
    }

    func offer(site: String, username: String, password: String) -> Offer {
        guard !password.isEmpty, !isNever(site) else { return .none }
        if let known = credentials.first(where: { $0.site == site && $0.username == username }) {
            return known.password == password ? .none : .update
        }
        // A password already saved under another name for this site (a form without a user name field): an update of it.
        if username.isEmpty, credentials.contains(where: { $0.site == site && $0.password == password }) { return .none }
        return .save
    }

    /// Saves a sign-in, or updates the one with the same site and user name.
    mutating func save(_ credential: BrowserCredential) {
        credentials.removeAll { $0.id == credential.id }
        credentials.append(credential)
        neverSites.removeAll { $0 == credential.site }
    }

    /// A saved sign-in was filled in: it moves to the front for its site.
    mutating func used(_ id: String, at date: Date = Date()) {
        guard let index = credentials.firstIndex(where: { $0.id == id }) else { return }
        credentials[index].lastUsed = date
    }

    mutating func remove(_ id: String) {
        credentials.removeAll { $0.id == id }
    }

    mutating func never(_ site: String) {
        if !neverSites.contains(site) { neverSites.append(site) }
    }

    mutating func allowAgain(_ site: String) {
        neverSites.removeAll { $0 == site }
    }
}
