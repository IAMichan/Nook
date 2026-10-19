import Foundation

// Apps that open inside Nook, next to the chat: "@open whatsapp" shows WhatsApp beside the conversation, so you chat in
// WhatsApp itself and ask Nook about it at the same time. When the app is installed on this Mac, that is the Mac app
// itself; otherwise its web version. Foundation only, so tests can use it independently; the web view lives in
// `EmbeddedAppView.swift`, the Mac app's live picture in `MacAppMirror.swift`.

/// An app Nook can show next to the chat: a web app, or an app installed on this Mac.
struct EmbeddedApp: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// The web address, or for a Mac app the `.app` bundle on disk.
    let url: URL
    /// SF Symbol for the pane's header and the `@` list.
    let symbol: String
    /// Other names people use for it ("wa", "app", "mail").
    var aliases: [String] = []

    /// Its own cookies and storage, kept across launches so a sign-in stays (WhatsApp would otherwise ask for the QR
    /// code every time), and separate per app so no app sees another's. The same id every launch.
    var storeID: UUID { EmbeddedAppCatalog.storeID(for: id) }

    /// An app installed on this Mac rather than a web app.
    var isMacApp: Bool { url.isFileURL }
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
        app("facebook", "Facebook", "https://www.facebook.com", "person.2.fill", ["fb"]),
        app("slack", "Slack", "https://app.slack.com/client", "number"),
        app("discord", "Discord", "https://discord.com/app", "gamecontroller.fill"),
        app("teams", "Teams", "https://teams.microsoft.com", "person.3.fill", ["microsoft teams"]),
        app("googlechat", "Google Chat", "https://chat.google.com", "bubble.left.fill", ["google chat", "gchat"]),
        app("meet", "Google Meet", "https://meet.google.com", "video.fill", ["google meet"]),
        app("zoom", "Zoom", "https://app.zoom.us", "video.circle.fill"),
        app("linkedin", "LinkedIn", "https://www.linkedin.com/messaging/", "person.crop.square.fill"),
        app("x", "X", "https://x.com", "xmark", ["twitter"]),
        app("threads", "Threads", "https://www.threads.net", "at"),
        app("bluesky", "Bluesky", "https://bsky.app", "cloud.fill", ["bsky"]),
        app("mastodon", "Mastodon", "https://mastodon.social", "bubble.left.and.text.bubble.right.fill"),
        app("reddit", "Reddit", "https://www.reddit.com", "text.bubble.fill"),
        app("tiktok", "TikTok", "https://www.tiktok.com", "music.note.tv"),
        app("snapchat", "Snapchat", "https://web.snapchat.com", "camera.viewfinder", ["snap"]),
        app("pinterest", "Pinterest", "https://www.pinterest.com", "pin.fill"),
        app("gmail", "Gmail", "https://mail.google.com", "envelope.fill", ["google mail"]),
        app("outlook", "Outlook", "https://outlook.office.com/mail/", "envelope.badge.fill", ["hotmail", "outlook mail"]),
        app("outlookcalendar", "Outlook Calendar", "https://outlook.office.com/calendar/", "calendar.badge.clock", ["outlook agenda"]),
        app("icloudmail", "iCloud Mail", "https://www.icloud.com/mail", "envelope.open.fill", ["icloud mail"]),
        app("icloud", "iCloud", "https://www.icloud.com", "icloud.fill"),
        app("proton", "Proton Mail", "https://mail.proton.me", "envelope.circle.fill", ["protonmail", "proton mail"]),
        app("calendar", "Google Calendar", "https://calendar.google.com", "calendar", ["google calendar", "google agenda", "gcal"]),
        app("calendly", "Calendly", "https://calendly.com/app", "calendar.badge.plus"),
        app("superhuman", "Superhuman", "https://mail.superhuman.com", "bolt.fill"),
        app("drive", "Google Drive", "https://drive.google.com", "externaldrive.fill", ["google drive"]),
        app("docs", "Google Docs", "https://docs.google.com/document/", "doc.richtext.fill", ["google docs"]),
        app("sheets", "Google Sheets", "https://docs.google.com/spreadsheets/", "tablecells.fill", ["google sheets"]),
        app("slides", "Google Slides", "https://docs.google.com/presentation/", "rectangle.on.rectangle", ["google slides"]),
        app("keep", "Google Keep", "https://keep.google.com", "note.text", ["google keep"]),
        app("onedrive", "OneDrive", "https://onedrive.live.com", "cloud.fill"),
        app("office", "Microsoft 365", "https://www.office.com", "square.grid.2x2.fill", ["office 365", "microsoft 365"]),
        app("word", "Word", "https://www.office.com/launch/word", "doc.text", ["microsoft word"]),
        app("excel", "Excel", "https://www.office.com/launch/excel", "tablecells", ["microsoft excel"]),
        app("powerpoint", "PowerPoint", "https://www.office.com/launch/powerpoint", "rectangle.stack.fill", ["microsoft powerpoint", "ppt"]),
        app("dropbox", "Dropbox", "https://www.dropbox.com/home", "shippingbox.fill"),
        app("box", "Box", "https://app.box.com", "archivebox.fill"),
        app("notion", "Notion", "https://www.notion.so", "doc.text.fill"),
        app("evernote", "Evernote", "https://www.evernote.com/client/web", "leaf.fill"),
        app("confluence", "Confluence", "https://home.atlassian.com", "book.closed.fill"),
        app("coda", "Coda", "https://coda.io/workspaces", "doc.on.doc.fill"),
        app("airtable", "Airtable", "https://airtable.com", "square.grid.3x3.fill"),
        app("miro", "Miro", "https://miro.com/app/dashboard/", "scribble.variable"),
        app("figma", "Figma", "https://www.figma.com/files/recents-and-sharing", "paintbrush.pointed.fill"),
        app("canva", "Canva", "https://www.canva.com", "paintpalette.fill"),
        app("excalidraw", "Excalidraw", "https://excalidraw.com", "pencil.and.outline"),
        app("todoist", "Todoist", "https://app.todoist.com", "checklist"),
        app("ticktick", "TickTick", "https://ticktick.com/webapp", "checkmark.circle.fill"),
        app("trello", "Trello", "https://trello.com", "rectangle.split.3x1.fill"),
        app("asana", "Asana", "https://app.asana.com", "circle.hexagongrid.fill"),
        app("linear", "Linear", "https://linear.app", "line.diagonal"),
        app("jira", "Jira", "https://home.atlassian.com", "square.stack.3d.up.fill"),
        app("clickup", "ClickUp", "https://app.clickup.com", "arrow.up.circle.fill"),
        app("monday", "Monday", "https://monday.com", "calendar.day.timeline.left", ["monday.com"]),
        app("basecamp", "Basecamp", "https://launchpad.37signals.com", "tent.fill"),
        app("github", "GitHub", "https://github.com", "chevron.left.forwardslash.chevron.right", ["gh"]),
        app("gitlab", "GitLab", "https://gitlab.com", "chevron.left.slash.chevron.right"),
        app("bitbucket", "Bitbucket", "https://bitbucket.org", "tray.full.fill"),
        app("vercel", "Vercel", "https://vercel.com/dashboard", "triangle.fill"),
        app("netlify", "Netlify", "https://app.netlify.com", "network"),
        app("supabase", "Supabase", "https://supabase.com/dashboard", "cylinder.fill"),
        app("firebase", "Firebase", "https://console.firebase.google.com", "flame.fill"),
        app("cloudflare", "Cloudflare", "https://dash.cloudflare.com", "cloud.sun.fill"),
        app("aws", "AWS Console", "https://console.aws.amazon.com", "server.rack", ["amazon web services"]),
        app("stackoverflow", "Stack Overflow", "https://stackoverflow.com", "square.stack.fill", ["stack overflow"]),
        app("sentry", "Sentry", "https://sentry.io", "exclamationmark.shield.fill"),
        app("codepen", "CodePen", "https://codepen.io", "curlybraces"),
        app("chatgpt", "ChatGPT", "https://chatgpt.com", "sparkles", ["openai"]),
        app("claude", "Claude", "https://claude.ai", "sparkle"),
        app("gemini", "Gemini", "https://gemini.google.com", "star.fill", ["bard"]),
        app("perplexity", "Perplexity", "https://www.perplexity.ai", "magnifyingglass.circle.fill"),
        app("copilot", "Copilot", "https://copilot.microsoft.com", "wand.and.stars", ["microsoft copilot"]),
        app("hubspot", "HubSpot", "https://app.hubspot.com", "person.crop.circle.badge.checkmark"),
        app("salesforce", "Salesforce", "https://login.salesforce.com", "cloud.bolt.fill"),
        app("stripe", "Stripe", "https://dashboard.stripe.com", "creditcard.fill"),
        app("shopify", "Shopify", "https://admin.shopify.com", "bag.fill"),
        app("paypal", "PayPal", "https://www.paypal.com/myaccount/summary", "dollarsign.circle.fill"),
        app("moneybird", "Moneybird", "https://moneybird.com", "bird.fill"),
        app("exact", "Exact Online", "https://start.exactonline.nl", "eurosign.circle.fill", ["exact online"]),
        app("intercom", "Intercom", "https://app.intercom.com", "bubble.left.and.exclamationmark.bubble.right.fill"),
        app("zendesk", "Zendesk", "https://www.zendesk.com/login/", "questionmark.bubble.fill"),
        app("mailchimp", "Mailchimp", "https://login.mailchimp.com", "paperplane.circle.fill"),
        app("analytics", "Google Analytics", "https://analytics.google.com", "chart.xyaxis.line", ["google analytics", "ga"]),
        app("searchconsole", "Search Console", "https://search.google.com/search-console", "magnifyingglass", ["google search console"]),
        app("youtube", "YouTube", "https://www.youtube.com", "play.rectangle.fill", ["yt"]),
        app("youtubemusic", "YouTube Music", "https://music.youtube.com", "music.note.list", ["youtube music", "yt music"]),
        app("spotify", "Spotify", "https://open.spotify.com", "music.note"),
        app("applemusic", "Apple Music", "https://music.apple.com", "music.quarternote.3", ["apple music"]),
        app("soundcloud", "SoundCloud", "https://soundcloud.com", "waveform"),
        app("netflix", "Netflix", "https://www.netflix.com", "tv.fill"),
        app("twitch", "Twitch", "https://www.twitch.tv", "gamecontroller"),
        app("primevideo", "Prime Video", "https://www.primevideo.com", "play.tv.fill", ["prime video", "amazon prime"]),
        app("disneyplus", "Disney+", "https://www.disneyplus.com", "sparkles.tv.fill", ["disney plus", "disney"]),
        app("videoland", "Videoland", "https://www.videoland.com", "film.fill"),
        app("npostart", "NPO Start", "https://npo.nl/start", "tv.circle.fill", ["npo", "npo start"]),
        app("maps", "Google Maps", "https://www.google.com/maps", "map.fill", ["google maps"]),
        app("translate", "Google Translate", "https://translate.google.com", "character.bubble.fill", ["google translate", "vertaal"]),
        app("deepl", "DeepL", "https://www.deepl.com/translator", "globe.europe.africa.fill"),
        app("photos", "Google Photos", "https://photos.google.com", "photo.on.rectangle.angled", ["google photos", "google foto's"]),
        app("wikipedia", "Wikipedia", "https://www.wikipedia.org", "book.fill", ["wiki"]),
        app("news", "Google News", "https://news.google.com", "newspaper.fill", ["google news", "nieuws"]),
        app("nos", "NOS", "https://nos.nl", "newspaper"),
        app("buienradar", "Buienradar", "https://www.buienradar.nl", "cloud.rain.fill"),
        app("amazon", "Amazon", "https://www.amazon.com", "cart.fill"),
        app("bol", "bol.com", "https://www.bol.com", "cart", ["bol.com", "bol"]),
        app("marktplaats", "Marktplaats", "https://www.marktplaats.nl", "tag.fill"),
        app("ns", "NS", "https://www.ns.nl/reisplanner", "tram.fill", ["ns reisplanner", "reisplanner"])
    ]

    private static func app(_ id: String, _ title: String, _ url: String, _ symbol: String, _ aliases: [String] = []) -> EmbeddedApp {
        EmbeddedApp(id: id, title: title, url: URL(string: url)!, symbol: symbol, aliases: aliases)
    }

    /// The app for a name as people type it: "WhatsApp", "whats app", "wa", "Google Calendar". An app installed on this
    /// Mac comes first; "whatsapp web" asks for the web version even then.
    static func find(_ raw: String, installed: [EmbeddedApp] = InstalledMacApps.all) -> EmbeddedApp? {
        let name = key(raw)
        guard !name.isEmpty else { return nil }
        let named = { (apps: [EmbeddedApp], name: String) in
            apps.first { app in ([app.id, app.title] + app.aliases).contains { key($0) == name } }
        }
        let words = raw.lowercased().split(whereSeparator: { $0.isWhitespace })
        if words.count > 1, words.last == "web" {
            return named(all, name) ?? named(all, key(words.dropLast().joined(separator: " ")))
        }
        return named(installed, name) ?? named(all, name)
    }

    /// Everything the `@` list offers: the Mac apps on this Mac, then the web apps that are not installed as one.
    static func available(installed: [EmbeddedApp] = InstalledMacApps.all) -> [EmbeddedApp] {
        let shadowed = Set(installed.flatMap { $0.aliases.map(key) })
        return installed + all.filter { !shadowed.contains(key($0.id)) }
    }

    /// The apps whose name starts with (then contains) what was typed, for the `@` list.
    static func matching(_ query: String, in apps: [EmbeddedApp] = all) -> [EmbeddedApp] {
        let q = key(query)
        guard !q.isEmpty else { return apps }
        let names = { (app: EmbeddedApp) in ([app.id, app.title] + app.aliases).map(key) }
        let starts = apps.filter { names($0).contains { $0.hasPrefix(q) } }
        let contains = apps.filter { app in !starts.contains(app) && names(app).contains { $0.contains(q) } }
        return starts + contains
    }

    /// Apps to suggest for a name Nook does not know ("@open whatsap"): those that match its start, otherwise the first
    /// apps of the catalog.
    static func suggestions(for name: String, limit: Int = 6, installed: [EmbeddedApp] = InstalledMacApps.all) -> [EmbeddedApp] {
        let typed = key(name)
        let apps = available(installed: installed)
        for length in stride(from: min(typed.count, 4), through: 2, by: -1) {
            let found = matching(String(typed.prefix(length)), in: apps)
            if !found.isEmpty { return Array(found.prefix(limit)) }
        }
        return Array(all.prefix(limit))
    }

    /// What to filter the `@` list by: "@op" or "@open" is on its way to "@open …" and lists every app, "@wh" filters.
    static func mentionQuery(_ query: String) -> String {
        let q = query.lowercased()
        return !q.isEmpty && "open".hasPrefix(q) ? "" : q
    }

    /// "@open whatsapp", "@whatsapp", "@close", "open whatsapp in nook". Nil for everything else, so a normal question
    /// that happens to start with "@" still goes to the brain.
    static func command(in raw: String, installed: [EmbeddedApp] = InstalledMacApps.all) -> EmbeddedAppCommand? {
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
            if let app = find(name, installed: installed) ?? webApp(name) { return .open(app) }
            return .unknown(name.trimmingCharacters(in: .whitespaces))
        }
        // "@whatsapp" alone: only a known app, so "@Lisa …" or an e-mail address is left alone.
        if let name = groups(#"^@([\p{L}\p{N}][\p{L}\p{N} .-]{0,30})$"#)?.first, let app = find(name, installed: installed) {
            return .open(app)
        }
        if let name = groups(#"^(?:open|start|toon|show|öffne|ouvre|abre)\s+(.+?)\s+(?:in|bij|im|dans|en)\s+nook[.!]?$"#)?.first,
           let app = find(name, installed: installed) ?? webApp(name) {
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

    static func key(_ raw: String) -> String {
        raw.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The apps installed on this Mac, for "@open": the `.app` bundles in the usual Applications folders. An app that also
/// has a web version in the catalog takes over its names ("wa" opens the WhatsApp Mac app) and its symbol; "@open
/// whatsapp web" still opens the web version.
enum InstalledMacApps {
    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                          NSHomeDirectory() + "/Applications"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (apps: [EmbeddedApp], at: Date)?

    /// Scanned again at most once a minute, so an app installed meanwhile shows up.
    static var all: [EmbeddedApp] {
        lock.lock()
        defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 60 { return cached.apps }
        let apps = make(paths: scan())
        cached = (apps, Date())
        return apps
    }

    /// The `.app` bundles in `folders`, and one folder deeper in /Applications ("/Applications/Microsoft Office/…").
    static func scan() -> [String] {
        let files = FileManager.default
        var paths: [String] = []
        for folder in folders {
            guard let names = try? files.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") {
                    paths.append(path)
                } else if folder == "/Applications", name != "Utilities",
                          let inner = try? files.contentsOfDirectory(atPath: path) {
                    paths += inner.sorted().filter { $0.hasSuffix(".app") }.map { path + "/" + $0 }
                }
            }
        }
        return paths
    }

    /// One app per name, the first path winning; Nook itself left out.
    static func make(paths: [String]) -> [EmbeddedApp] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let title = String(URL(fileURLWithPath: path).lastPathComponent.dropLast(4))
            let name = EmbeddedAppCatalog.key(title)
            guard !name.isEmpty, name != "nook", seen.insert(name).inserted else { return nil }
            // By title or alias, not by id: Apple's Calendar is not Google Calendar (id "calendar").
            let web = EmbeddedAppCatalog.all.first { app in
                ([app.title] + app.aliases).contains { EmbeddedAppCatalog.key($0) == name }
            }
            let aliases = web.map { [$0.id, $0.title] + $0.aliases } ?? []
            return EmbeddedApp(id: "mac:" + name, title: title, url: URL(fileURLWithPath: path, isDirectory: true),
                               symbol: web?.symbol ?? "macwindow", aliases: aliases)
        }
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

/// Where a point on the live picture of a Mac app lands in the app's real window. The picture is the window scaled to fit
/// the pane (aspect kept, centred), so a click at `local` in a `view`-sized pane is a click at the returned point on
/// screen. All in top-left-origin coordinates; nil for a point in the empty margin beside the picture.
enum MirrorGeometry {
    static func screenPoint(_ local: CGPoint, view: CGSize, window: CGRect) -> CGPoint? {
        guard window.width > 0, window.height > 0, view.width > 0, view.height > 0 else { return nil }
        let scale = min(view.width / window.width, view.height / window.height)
        let originX = (view.width - window.width * scale) / 2
        let originY = (view.height - window.height * scale) / 2
        let x = (local.x - originX) / scale
        let y = (local.y - originY) / scale
        guard x >= 0, y >= 0, x <= window.width, y <= window.height else { return nil }
        return CGPoint(x: window.minX + x, y: window.minY + y)
    }
}
