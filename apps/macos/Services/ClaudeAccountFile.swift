import Foundation

/// What Claude Code's account file (`.claude.json`) says about its login. The file is often several megabytes (it keeps
/// history per project) and Nook asks it several times a minute (accounts): it is parsed again only
/// when its modification date or size changed.
enum ClaudeAccountFile {
    struct Account: Equatable, Sendable {
        var email: String?
        var displayName: String?
        var organizationName: String?
        var organizationID: String?
        /// subscriptionType, planType and rateLimitTier, when set.
        var plan: [String: String]
        var hasOAuth: Bool
        var hasAPIKey: Bool
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: (modified: Date, size: Int, account: Account?)] = [:]

    /// Nil when the file is missing or is no JSON object.
    static func read(_ url: URL) -> Account? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        lock.lock()
        if let hit = cache[url.path], hit.modified == modified, hit.size == size {
            lock.unlock()
            return hit.account
        }
        lock.unlock()
        let account = parse(url)
        lock.lock()
        cache[url.path] = (modified, size, account)
        lock.unlock()
        return account
    }

    static func parse(_ url: URL) -> Account? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let oauth = root["oauthAccount"] as? [String: Any]
        var plan: [String: String] = [:]
        for key in ["subscriptionType", "planType", "rateLimitTier"] {
            if let value = oauth?[key] as? String { plan[key] = value }
        }
        return Account(email: oauth?["emailAddress"] as? String, displayName: oauth?["displayName"] as? String,
                       organizationName: oauth?["organizationName"] as? String, organizationID: oauth?["organizationUuid"] as? String,
                       plan: plan, hasOAuth: oauth != nil, hasAPIKey: root["primaryApiKey"] != nil)
    }
}
