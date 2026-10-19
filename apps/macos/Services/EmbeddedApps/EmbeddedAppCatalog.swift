import Foundation

// Apps that open inside Nook, next to the chat: "@open whatsapp" shows WhatsApp Web beside the conversation, so you
// chat in WhatsApp itself and ask Nook about it at the same time. Foundation only, so tests can use it independently;
// the web view lives in `EmbeddedAppView.swift`.

/// A web app Nook can show next to the chat.
struct EmbeddedApp: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let url: URL
    /// SF Symbol for the pane's header and the `@` list.
    let symbol: String
    /// Other names people use for it ("wa", "app", "mail").
    var aliases: [String] = []

    /// Its own cookies and storage, kept across launches so a sign-in stays (WhatsApp would otherwise ask for the QR
    /// code every time), and separate per app so no app sees another's. The same id every launch.
    var storeID: UUID { EmbeddedAppCatalog.storeID(for: id) }
}

/// What a chat message asks of the embedded apps.
enum EmbeddedAppCommand: Equatable, Sendable {
    case open(EmbeddedApp)
    case close
    /// "@open something" that is no known app and no web address.
    case unknown(String)
}

enum EmbeddedAppCatalog {
    static let all: [EmbeddedApp] = [
        app("whatsapp", "WhatsApp", "https://web.whatsapp.com", "bubble.left.and.bubble.right.fill", ["wa", "whats app", "app", "whatsapp web"]),
        app("telegram", "Telegram", "https://web.telegram.org/a/", "paperplane.fill"),
        app("messenger", "Messenger", "https://www.messenger.com", "message.fill", ["facebook messenger"]),
        app("instagram", "Instagram", "https://www.instagram.com/direct/inbox/", "camera.fill", ["insta", "ig"]),
        app("slack", "Slack", "https://app.slack.com/client", "number"),
        app("discord", "Discord", "https://discord.com/app", "gamecontroller.fill"),
        app("teams", "Teams", "https://teams.microsoft.com", "person.3.fill", ["microsoft teams"]),
        app("gmail", "Gmail", "https://mail.google.com", "envelope.fill", ["google mail"]),
        app("outlook", "Outlook", "https://outlook.office.com/mail/", "envelope.badge.fill", ["hotmail"]),
        app("calendar", "Google Calendar", "https://calendar.google.com", "calendar", ["google calendar", "google agenda"]),
        app("drive", "Google Drive", "https://drive.google.com", "externaldrive.fill", ["google drive"]),
        app("notion", "Notion", "https://www.notion.so", "doc.text.fill"),
        app("linkedin", "LinkedIn", "https://www.linkedin.com/messaging/", "person.crop.square.fill"),
        app("x", "X", "https://x.com", "xmark", ["twitter"]),
        app("youtube", "YouTube", "https://www.youtube.com", "play.rectangle.fill"),
        app("spotify", "Spotify", "https://open.spotify.com", "music.note")
    ]

    private static func app(_ id: String, _ title: String, _ url: String, _ symbol: String, _ aliases: [String] = []) -> EmbeddedApp {
        EmbeddedApp(id: id, title: title, url: URL(string: url)!, symbol: symbol, aliases: aliases)
    }

    /// The app for a name as people type it: "WhatsApp", "whats app", "wa", "Google Calendar".
    static func find(_ raw: String) -> EmbeddedApp? {
        let name = key(raw)
        guard !name.isEmpty else { return nil }
        return all.first { app in ([app.id, app.title] + app.aliases).contains { key($0) == name } }
    }

    /// The apps whose name starts with (then contains) what was typed, for the `@` list.
    static func matching(_ query: String) -> [EmbeddedApp] {
        let q = key(query)
        guard !q.isEmpty else { return all }
        let names = { (app: EmbeddedApp) in ([app.id, app.title] + app.aliases).map(key) }
        let starts = all.filter { names($0).contains { $0.hasPrefix(q) } }
        let contains = all.filter { app in !starts.contains(app) && names(app).contains { $0.contains(q) } }
        return starts + contains
    }

    /// What to filter the `@` list by: "@op" or "@open" is on its way to "@open …" and lists every app, "@wh" filters.
    static func mentionQuery(_ query: String) -> String {
        let q = query.lowercased()
        return !q.isEmpty && "open".hasPrefix(q) ? "" : q
    }

    /// "@open whatsapp", "@whatsapp", "@close", "open whatsapp in nook". Nil for everything else, so a normal question
    /// that happens to start with "@" still goes to the brain.
    static func command(in raw: String) -> EmbeddedAppCommand? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
        if lower.range(of: #"^@(close|sluit|schließe|schliesse|ferme|fermer|cierra|cerrar)\b"#, options: .regularExpression) != nil {
            return .close
        }
        if let name = groups(#"^@(?:open|openen|öffne|oeffne|ouvre|ouvrir|abre|abrir)\s+(.+?)[.!]?$"#)?.first {
            if let app = find(name) ?? webApp(name) { return .open(app) }
            return .unknown(name.trimmingCharacters(in: .whitespaces))
        }
        // "@whatsapp" alone: only a known app, so "@Lisa …" or an e-mail address is left alone.
        if let name = groups(#"^@([\p{L}\p{N}][\p{L}\p{N} .-]{0,30})$"#)?.first, let app = find(name) {
            return .open(app)
        }
        if let name = groups(#"^(?:open|start|toon|show|öffne|ouvre|abre)\s+(.+?)\s+(?:in|bij|im|dans|en)\s+nook[.!]?$"#)?.first,
           let app = find(name) ?? webApp(name) {
            return .open(app)
        }
        return nil
    }

    /// "@open notion.so/my-page": any https web address opens as an app of its own.
    static func webApp(_ raw: String) -> EmbeddedApp? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(" "), text.contains("."), !text.contains("@") else { return nil }
        if text.lowercased().hasPrefix("http://") { return nil }
        if !text.lowercased().hasPrefix("https://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host?.lowercased(), host.contains("."),
              host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return EmbeddedApp(id: "web:" + name, title: name, url: url, symbol: "globe")
    }

    /// A stable UUID for an app id: two FNV-1a hashes side by side, the same on every launch and Mac.
    static func storeID(for id: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var hash = seed
            for byte in ("nook.embedded." + id).utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            return hash
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: a >> (UInt64(index) * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: b >> (UInt64(index) * 8))
        }
        // Version 4 / RFC 4122 variant bits, so it is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func key(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The line between the chat and an open app: how wide the chat may be, so neither side gets too narrow to use.
enum EmbeddedSplit {
    static let defaultChatWidth: Double = 400
    static let minimumChat: Double = 300
    static let minimumApp: Double = 380
    /// Room the line itself takes between the two.
    static let handle: Double = 16

    /// `wanted` kept between the chat's minimum and what leaves the app its minimum. Before the total width is known
    /// (0), only the chat's minimum applies.
    static func chatWidth(_ wanted: Double, total: Double) -> Double {
        let most = total > 0 ? max(minimumChat, total - minimumApp - handle) : .infinity
        return min(max(wanted, minimumChat), most)
    }
}
