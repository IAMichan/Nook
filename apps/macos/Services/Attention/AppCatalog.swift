import Foundation

/// What kind of app something is.
enum AppKind: String, CaseIterable, Codable, Sendable {
    case mail, browser, editor, terminal, chat, spreadsheet, document, calendar, pdf, design, call
}

/// One list of the apps Nook knows by kind, by bundle ID and by name: a browser, a call app, a chat app, a mail app, an
/// editor, a terminal. Quiet mode (a call with the microphone open, a browser's sharing bar), double tap (a reply box),
/// the starter suggestions (what is in front), autocomplete (Chromium's accessibility tree), the UI driver (typing into a
/// web page) and the browser connectors all ask here, so an app added once is known everywhere. An app can be more than
/// one kind: WhatsApp is where you chat and where you call. Foundation only; tested in AppCatalogTests.
enum AppCatalog {
    // MARK: Browsers

    /// The engine a browser is built on: Chromium builds its accessibility tree only when asked, Safari and Chromium are
    /// read through AppleScript.
    enum Engine: String, Sendable { case webkit, chromium, gecko }

    /// A browser by its bundle ID. `readable`: Nook reads its open tab (`read_browser_tab`, the browser connector).
    struct Browser: Equatable, Sendable {
        var name: String
        var bundleID: String
        var engine: Engine
        var readable = false
    }

    /// The browsers Nook knows, the ones it reads tabs from first, in the order it tries them.
    static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", engine: .webkit, readable: true),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", engine: .chromium, readable: true),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", engine: .chromium, readable: true),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser", engine: .chromium, readable: true),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", engine: .chromium, readable: true),
        Browser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview", engine: .webkit),
        Browser(name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta", engine: .chromium),
        Browser(name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary", engine: .chromium),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", engine: .chromium),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera", engine: .chromium),
        Browser(name: "Comet", bundleID: "ai.perplexity.comet", engine: .chromium),
        Browser(name: "ChatGPT Atlas", bundleID: "com.openai.atlas", engine: .chromium),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", engine: .chromium),
        Browser(name: "Firefox", bundleID: "org.mozilla.firefox", engine: .gecko),
        Browser(name: "Orion", bundleID: "com.kagi.kagimacOS", engine: .webkit),
        Browser(name: "Zen", bundleID: "app.zen-browser.zen", engine: .gecko),
    ]

    /// The browsers whose open tab Nook reads, in the order it tries them.
    static var readableBrowsers: [Browser] { browsers.filter(\.readable) }

    /// Browsers built on Chromium, by bundle ID.
    static let chromiumBundles: Set<String> = Set(browsers.filter { $0.engine == .chromium && $0.bundleID != "org.chromium.Chromium" }.map(\.bundleID))

    /// Browsers by bundle ID prefix: their helpers (which hold the microphone) share it ("com.google.Chrome.helper").
    static let browserBundlePrefixes: [String] = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser",
                                                  "com.vivaldi.Vivaldi", "com.operasoftware", "org.mozilla.firefox", "com.apple.Safari",
                                                  "com.apple.WebKit", "com.kagi.kagimacOS", "app.zen-browser", "org.chromium.Chromium",
                                                  "ai.perplexity.comet", "com.openai.atlas"]

    static func isBrowser(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && browserBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Browsers by a word of their name or bundle ID, lowercased: for a window owner ("Google Chrome") when only that is known.
    static let browserNames: [String] = ["chrome", "chromium", "edge", "brave", "arc", "vivaldi", "opera", "firefox", "safari", "orion", "zen"]

    // MARK: Calls

    /// Apps you hold calls in, by bundle ID; while one of them has the microphone open, you are in a call.
    static let callBundles: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
                                           "com.cisco.webex.meetings", "com.apple.FaceTime", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
                                           "co.teamport.around", "com.skype.skype", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                                           "com.gather.Gather"]

    /// A call app, also a helper of one ("us.zoom.xos.helper").
    static func isCallApp(_ bundleID: String) -> Bool {
        callBundles.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// Call apps by a word of their name, lowercased: their sharing bar says "share" in its window name.
    static let callNames: [String] = ["zoom", "teams", "webex", "slack", "discord", "facetime", "whereby", "around", "gather"]

    // MARK: Chat and mail

    /// Apps where you write to people, by bundle ID.
    static let chatBundles: Set<String> = [
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2", "com.microsoft.teams", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.hnc.Discord", "com.facebook.archon", "com.beeper.beeper-desktop",
        "com.automattic.beeper.desktop",
    ]

    /// Mail apps, by bundle ID.
    static let mailBundles: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac"]

    /// Apps whose text box is where you answer someone: chat and mail.
    static var replyBundles: Set<String> { chatBundles.union(mailBundles) }

    // MARK: By kind

    /// Every kind an app is, by its bundle ID alone.
    static func kinds(bundleID: String) -> Set<AppKind> {
        var kinds = Set<AppKind>()
        if isBrowser(bundleID) { kinds.insert(.browser) }
        if isCallApp(bundleID) { kinds.insert(.call) }
        if chatBundles.contains(bundleID) { kinds.insert(.chat) }
        if mailBundles.contains(bundleID) { kinds.insert(.mail) }
        return kinds
    }

    /// Words of an app's name or bundle ID per kind, lowercased, for apps known only loosely ("cursor", "ghostty").
    /// `kind(app:bundleID:)` tries the kinds in `nameOrder`.
    static let nameKeywords: [AppKind: [String]] = [
        .mail: ["com.apple.mail", "outlook", "spark", "superhuman", "mimestream"],
        .browser: ["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "orion"],
        .editor: ["xcode", "vscode", "com.microsoft.vscode", "cursor", "zed", "jetbrains", "sublime", "nova", "windsurf"],
        .terminal: ["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty"],
        .chat: ["slack", "whatsapp", "telegram", "discord", "teams", "mobilesms", "messages", "signal"],
        .spreadsheet: ["numbers", "excel", "sheets", "airtable"],
        .document: ["pages", "word", "notes", "notion", "obsidian", "bear", "craft", "docs", "textedit"],
        .calendar: ["ical", "calendar", "fantastical", "busycal", "notion-calendar"],
        .pdf: ["preview", "pdf", "acrobat", "skim"],
        .design: ["figma", "sketch", "framer"],
        .call: ["zoom", "facetime", "meet", "webex"],
    ]

    /// The order the loose kinds are tried in: a mail app before a browser, an editor before a document.
    static let nameOrder: [AppKind] = [.mail, .browser, .editor, .terminal, .chat, .spreadsheet, .document, .calendar, .pdf, .design, .call]

    /// The kind of the app in front, by its name and bundle ID: the first kind whose words either holds. Nil for an app
    /// Nook does not know.
    static func kind(app: String, bundleID: String) -> AppKind? {
        let id = bundleID.lowercased(), name = app.lowercased()
        return nameOrder.first { kind in
            (nameKeywords[kind] ?? []).contains { id.contains($0) || name.contains($0) }
        }
    }
}
