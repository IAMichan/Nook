import Foundation

// What you typed and did not send yet, kept per place you write (a session, a chat with Nook, a chat in your apps, the
// New session sheet), as the Mac's composer keeps a draft per session (`ComposerDraftStore`). Leaving a conversation
// and coming back, or the app being closed, no longer loses it. Foundation only, so it is tested on the Mac (NookTests).

struct PhoneDrafts {
    /// Where a draft belongs.
    enum Place: Hashable {
        case session(String)
        case nookChat(String)
        case newNookChat
        case chat(String)
        case newSession

        var key: String {
            switch self {
            case .session(let id): return "session:" + id
            case .nookChat(let id): return "nook:" + id
            case .newNookChat: return "nook:new"
            case .chat(let id): return "chat:" + id
            case .newSession: return "new-session"
            }
        }
    }

    /// The most drafts kept: the oldest go first.
    static let limit = 40
    /// The longest draft kept, in characters.
    static let maxLength = 20_000
    static let defaultsKey = "phoneComposerDrafts"

    private struct Draft: Codable {
        var text: String
        var at: Double
    }

    let defaults: UserDefaults
    var now: () -> Date = Date.init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The draft for `place`; empty when there is none.
    func text(_ place: Place) -> String {
        load()[place.key]?.text ?? ""
    }

    /// Keeps `text` for `place`, or forgets the draft when it is only white space (sent, or cleared).
    func set(_ text: String, for place: Place) {
        var all = load()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard all.removeValue(forKey: place.key) != nil else { return }
        } else {
            let clipped = String(text.prefix(Self.maxLength))
            guard all[place.key]?.text != clipped else { return }
            all[place.key] = Draft(text: clipped, at: now().timeIntervalSince1970)
            if all.count > Self.limit {
                let oldest = all.sorted { $0.value.at < $1.value.at }.prefix(all.count - Self.limit).map(\.key)
                for key in oldest { all.removeValue(forKey: key) }
            }
        }
        save(all)
    }

    /// Forgets every draft (unpairing).
    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func load() -> [String: Draft] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let all = try? JSONDecoder().decode([String: Draft].self, from: data) else { return [:] }
        return all
    }

    private func save(_ all: [String: Draft]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
