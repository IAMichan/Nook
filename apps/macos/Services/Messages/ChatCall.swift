// Calling someone from the Chats tab, the same for every chat app: a voice or video button in the chat's header and in
// its info. No chat app lets another app hold a call for it, so Nook asks the app itself: straight into the call where
// its link does that (FaceTime for Messages, Teams, Skype), else into the chat in its app, where you press call. While
// the call goes on, Nook follows it by the app holding the microphone (`ChatCallTracker`) and shows how long it lasts and
// which microphone, sound and camera it uses. Foundation only, so it is tested anywhere.
import Foundation

/// Voice only, or with video.
enum ChatCallKind: String, Codable, Equatable, Sendable {
    case voice
    case video
}

/// How a chat's app takes a call from Nook.
enum ChatCallLaunch: Equatable, Sendable {
    /// A link the app opens straight into the call.
    case direct(URL)
    /// A link that opens this chat in its app, where you press call.
    case chat(URL)
    /// The app opens (no link to the chat Nook can make), and you press call in the chat there.
    case app

    var url: URL? {
        switch self {
        case .direct(let url), .chat(let url): return url
        case .app: return nil
        }
    }

    /// The call starts without another step from you.
    var isDirect: Bool {
        if case .direct = self { return true }
        return false
    }
}

/// Who a call goes to, as far as their chat's app said (`ChatsEntry`, `ChatProfile`).
struct ChatCallPerson: Equatable, Sendable {
    /// The app's source id ("whatsapp").
    var app: String
    var name: String
    var phone: String? = nil
    var email: String? = nil
    var username: String? = nil
    var isGroup = false
}

enum ChatCalls {
    /// The apps that hold calls at all, by source id. A mail app, LinkedIn and an app you added yourself have none.
    static let callingApps: Set<String> = ["whatsapp", "telegram", "instagram", "messenger", "signal", "messages", "slack",
                                           "discord", "teams", "googlechat", "snapchat", "viber", "wechat", "line", "skype",
                                           "element", "threema", "wire", "x"]

    /// The apps that also call a group, in the group's chat in the app.
    static let groupCallingApps: Set<String> = ["whatsapp", "telegram", "messenger", "signal", "slack", "discord", "teams",
                                                "googlechat", "element", "wire", "line", "wechat", "viber", "skype"]

    /// How `person`'s app takes this call; nil when the app has no calls (or none for a group).
    static func launch(_ kind: ChatCallKind, for person: ChatCallPerson) -> ChatCallLaunch? {
        if person.isGroup { return groupCallingApps.contains(person.app) ? .app : nil }
        guard callingApps.contains(person.app) else { return nil }
        let phone = person.phone.flatMap(phoneDigits)
        let username = person.username.flatMap(cleanUsername)
        let email = person.email.flatMap(cleanEmail)
        switch person.app {
        case "messages":
            // Messages has no calls of its own: FaceTime calls the same number or address.
            return faceTime(kind, handle: phone ?? email).map(ChatCallLaunch.direct) ?? .app
        case "teams":
            // Teams' call link: https://learn.microsoft.com/microsoftteams/platform/concepts/build-and-test/deep-link-teams
            guard let email, let url = link("msteams:/l/call/0/0", ["users": email, "withVideo": kind == .video ? "true" : "false"])
            else { return .app }
            return .direct(url)
        case "skype":
            guard let username, let url = URL(string: "skype:" + username + "?call" + (kind == .video ? "&video=true" : "")) else { return .app }
            return .direct(url)
        case "whatsapp":
            guard let phone, let url = link("whatsapp://send", ["phone": String(phone.dropFirst())]) else { return .app }
            return .chat(url)
        case "telegram":
            if let username, let url = link("tg://resolve", ["domain": username]) { return .chat(url) }
            if let phone, let url = link("tg://resolve", ["phone": String(phone.dropFirst())]) { return .chat(url) }
            return .app
        case "signal":
            guard let phone, let url = URL(string: "sgnl://signal.me/#p/" + phone) else { return .app }
            return .chat(url)
        case "viber":
            guard let phone, let url = link("viber://chat", ["number": phone]) else { return .app }
            return .chat(url)
        default:
            return .app
        }
    }

    /// A FaceTime call to a number or address on this Mac (with an iPhone nearby, a number can go as a phone call).
    static func faceTime(_ kind: ChatCallKind, handle: String?) -> URL? {
        guard let handle = handle?.trimmingCharacters(in: .whitespaces), !handle.isEmpty,
              let encoded = handle.addingPercentEncoding(withAllowedCharacters: handleCharacters) else { return nil }
        return URL(string: (kind == .video ? "facetime://" : "facetime-audio://") + encoded)
    }

    /// A number or address goes into a FaceTime link as written ("+31612345678", "anna@example.com").
    private static let handleCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+@._-"))

    /// The apps that hold a FaceTime call's microphone.
    static let faceTimeBundles = ["com.apple.FaceTime", "com.apple.avconferenced", "com.apple.TelephonyUtilities"]

    /// "+31 6 1234 5678" → "+31612345678"; nil for what is no phone number (a username, an address, too few digits).
    /// Without a "+" or "00" the number stays as written (a local number), with a "+" before it.
    static func phoneDigits(_ text: String) -> String? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A WhatsApp id ("31612345678@s.whatsapp.net") is its number.
        if let at = raw.firstIndex(of: "@") {
            let host = raw[raw.index(after: at)...]
            guard host.hasSuffix("whatsapp.net") || host == "c.us" else { return nil }
            raw = String(raw[..<at])
        }
        guard raw.allSatisfy({ $0.isNumber || "+-() .".contains($0) }) else { return nil }
        var digits = raw.filter(\.isNumber)
        if raw.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        guard (7...15).contains(digits.count) else { return nil }
        return "+" + digits
    }

    private static func cleanUsername(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
        return name
    }

    private static func cleanEmail(_ text: String) -> String? {
        let mail = text.trimmingCharacters(in: .whitespaces)
        guard mail.contains("@"), !mail.contains(" ") else { return nil }
        return mail
    }

    private static func link(_ base: String, _ query: [String: String]) -> URL? {
        guard var parts = URLComponents(string: base) else { return nil }
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A "+" in a query means a space to many apps.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }

    /// Whether one of `bundles` (or a helper of it, "com.hnc.Discord.helper") has the microphone open.
    static func holdsMicrophone(_ bundles: [String], microphoneApps: [String]) -> Bool {
        microphoneApps.contains { app in bundles.contains { app == $0 || app.hasPrefix($0 + ".") } }
    }
}

/// Where a call stands, by whether its app holds the microphone: calling until it does, then live, then ended once it let
/// go for a few seconds. A call that never got the microphone ends on its own after a while, as does the line that said
/// it ended.
struct ChatCallTracker: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case calling
        case live(since: Date)
        case ended(duration: TimeInterval, at: Date)
    }

    /// How long a call may ring (or wait for you to press call in its app) before Nook stops following it.
    static let connectWait: TimeInterval = 180
    /// How long the microphone may be let go during a call (an app switching devices) before the call counts as ended.
    static let dropGrace: TimeInterval = 6
    /// How long "Call ended" stays.
    static let endedShown: TimeInterval = 5

    let started: Date
    private(set) var phase: Phase = .calling
    private var lastHeard: Date?

    init(started: Date) {
        self.started = started
    }

    /// Takes a reading; returns false once the call is over and nothing more shows.
    mutating func observe(inCall: Bool, at now: Date) -> Bool {
        switch phase {
        case .calling:
            if inCall {
                phase = .live(since: now)
                lastHeard = now
            } else if now.timeIntervalSince(started) > Self.connectWait {
                return false
            }
        case .live(let since):
            if inCall {
                lastHeard = now
            } else if let heard = lastHeard, now.timeIntervalSince(heard) > Self.dropGrace {
                phase = .ended(duration: max(0, heard.timeIntervalSince(since)), at: now)
            }
        case .ended(_, let at):
            return now.timeIntervalSince(at) <= Self.endedShown
        }
        return true
    }

    /// "4:07", "1:02:33".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// What a person's info shows besides what their app said: the groups you share with them, from every chat the inbox
/// holds of the same app, the same way for every app that lists a group's people.
enum ChatCommonGroups {
    /// The groups of `app` whose people include `name`, newest first.
    static func groups(with name: String, app: String, in threads: [InboxThread]) -> [InboxThread] {
        let wanted = fold(name)
        guard !wanted.isEmpty else { return [] }
        let shared = threads.filter { (thread: InboxThread) -> Bool in
            guard thread.app == app, thread.isGroup, let members = thread.members else { return false }
            return members.contains { (member: String) in fold(member) == wanted }
        }
        return shared.sorted { (a: InboxThread, b: InboxThread) in a.last > b.last }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}
