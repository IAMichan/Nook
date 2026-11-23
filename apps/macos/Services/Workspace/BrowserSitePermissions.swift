import Foundation

/// What you allowed or refused each site in Nook's browser for your camera and microphone. A site asks once; when you
/// tick "Remember for this site" the answer stays until you take it back in Settings › Browser, as in Safari's website
/// settings. Kept by host, so every page of a site shares the answer. Foundation only, so tests can use it.
final class BrowserSitePermissions: @unchecked Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case camera, microphone
    }

    struct Entry: Equatable, Identifiable, Sendable {
        let host: String
        let kind: Kind
        let allowed: Bool
        var id: String { "\(host)|\(kind.rawValue)" }
    }

    static let shared = BrowserSitePermissions(defaults: .standard)
    static let key = "browser.sitePermissions"
    /// Posted on the main queue after an answer was saved or taken back, so Settings updates.
    static let changed = Notification.Name("BrowserSitePermissions.changed")

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var stored: [String: Bool] {
        get { defaults.dictionary(forKey: Self.key) as? [String: Bool] ?? [:] }
        set { defaults.set(newValue, forKey: Self.key) }
    }

    /// The saved answer for everything a site asks for at once: true or false when you answered all of it the same way,
    /// nil when it has to ask (one of them was never answered, or they differ).
    func decision(host: String, kinds: [Kind]) -> Bool? {
        let answers = kinds.map { stored[Entry(host: host.lowercased(), kind: $0, allowed: true).id] }
        guard let first = answers.first ?? nil, answers.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    func remember(host: String, kinds: [Kind], allowed: Bool) {
        var all = stored
        for kind in kinds { all[Entry(host: host.lowercased(), kind: kind, allowed: allowed).id] = allowed }
        stored = all
        announce()
    }

    func forget(_ entry: Entry) {
        var all = stored
        all[entry.id] = nil
        stored = all
        announce()
    }

    /// Every saved answer, by site and then camera before microphone.
    var entries: [Entry] {
        stored.compactMap { id, allowed -> Entry? in
            let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = Kind(rawValue: parts[1]) else { return nil }
            return Entry(host: parts[0], kind: kind, allowed: allowed)
        }
        .sorted { $0.host == $1.host ? $0.kind.rawValue < $1.kind.rawValue : $0.host < $1.host }
    }

    private func announce() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}
