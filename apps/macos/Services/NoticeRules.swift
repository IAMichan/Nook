import Foundation

/// Where a notice comes from (Settings › Notifications). Each source has one way of showing, and each app within it can
/// be switched on or off on its own.
enum NoticeSource: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Coding agents, in a terminal or in Nook: done, failed, or waiting on you.
    case agents
    /// A new message in a chat app (WhatsApp through the linked phone, and the apps whose chats Nook collects).
    case chats
    /// Nook himself: an answer that finished while you looked elsewhere, call notes that are ready.
    case nook
    /// Think Along: an offer about what is on your screen. Its apps are the ones you work in (by bundle id); one switched
    /// off is not looked at all.
    case suggestions

    var id: String { rawValue }
    var titleKey: String { "notices.source.\(rawValue)" }
    var detailKey: String { "notices.source.\(rawValue).detail" }
}

/// How a notice shows.
enum NoticeStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    /// A card on the notch, with its content and buttons.
    case card
    /// One slim line under the notch, with a button that opens it.
    case strip
    /// A macOS notification; a click opens it in Nook.
    case system
    /// Nothing pops up: the notice is only kept in the list under the bell (and in its own tab).
    case off

    var id: String { rawValue }
    var titleKey: String { "notices.style.\(rawValue)" }
}

/// What to do with one notice, once the rules, the app and the moment are weighed.
enum NoticeDecision: Equatable, Sendable {
    /// Show it this way (never `.off`).
    case show(NoticeStyle)
    /// Keep it in the history only: no pop-up, no sound.
    case historyOnly

    var style: NoticeStyle? {
        if case .show(let style) = self { return style }
        return nil
    }
}

/// Your choices for notices, in one place: how each source shows, and which apps may notify at all. Pure, so what a
/// notice does can be tested without a Mac; `AppSettings` keeps it and `AppModel.deliverNotice` follows it.
struct NoticeRules: Codable, Equatable, Sendable {
    /// How each source shows; a source missing here uses its default.
    var styles: [String: NoticeStyle] = [:]
    /// Apps switched on or off by you, by `appKey`; an app missing here uses its default.
    var apps: [String: Bool] = [:]

    /// The way each source shows until you choose.
    static func defaultStyle(_ source: NoticeSource) -> NoticeStyle {
        switch source {
        case .agents, .chats, .nook: return .card
        // A suggestion is never urgent: a line under the notch that opens into its card.
        case .suggestions: return .strip
        }
    }

    /// Whether an app may notify until you choose. Chat apps other than WhatsApp show their own macOS notifications
    /// already (that is where Nook reads them), so Nook stays quiet about them unless you ask.
    static func defaultOn(_ source: NoticeSource, app: String) -> Bool {
        switch source {
        case .agents, .nook, .suggestions: return true
        case .chats: return app == "whatsapp"
        }
    }

    /// The key an app is kept under: "agents:codex", "chats:telegram". Agent names ("Claude Code") are folded so a
    /// terminal session and a session Nook runs share one switch.
    static func appKey(_ source: NoticeSource, app: String) -> String {
        source.rawValue + ":" + normalizedApp(app)
    }

    static func normalizedApp(_ app: String) -> String {
        app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func style(for source: NoticeSource) -> NoticeStyle {
        styles[source.rawValue] ?? Self.defaultStyle(source)
    }

    mutating func setStyle(_ style: NoticeStyle, for source: NoticeSource) {
        styles[source.rawValue] = style == Self.defaultStyle(source) ? nil : style
    }

    /// Whether `app` may notify. An empty app (a notice that comes from no app in particular) always may.
    func isOn(_ source: NoticeSource, app: String) -> Bool {
        let name = Self.normalizedApp(app)
        guard !name.isEmpty else { return true }
        return apps[Self.appKey(source, app: name)] ?? Self.defaultOn(source, app: name)
    }

    mutating func set(_ source: NoticeSource, app: String, on: Bool) {
        let name = Self.normalizedApp(app)
        guard !name.isEmpty else { return }
        apps[Self.appKey(source, app: name)] = on == Self.defaultOn(source, app: name) ? nil : on
    }

    /// Whether any source shows as macOS notifications, so Nook asks macOS for permission.
    var usesSystem: Bool { NoticeSource.allCases.contains { style(for: $0) == .system } }

    /// What one notice does.
    /// - `urgent`: an agent waits for your decision (a permission request, a question). It always reaches you, also
    ///   with its source or app switched off and in a meeting: as a macOS notification when that is your choice, else
    ///   as a card.
    /// - `quiet`: you share your screen or sit in a meeting and chose quiet for it.
    /// - `watching`: you are looking at what it is about already.
    func decide(_ source: NoticeSource, app: String = "", urgent: Bool = false, quiet: Bool = false,
                watching: Bool = false) -> NoticeDecision {
        let style = style(for: source)
        if urgent { return .show(style == .system ? .system : .card) }
        guard !watching, !quiet, style != .off, isOn(source, app: app) else { return .historyOnly }
        return .show(style)
    }

    // MARK: Before these rules

    /// The rules from the choices that came before them: agent notices as a card, one line or macOS notification, and
    /// WhatsApp's own "show new messages" switch, and the apps Think Along was muted in.
    static func migrated(agentNotice: String?, noticeDelivery: String?, whatsAppNotify: Bool?,
                         thinkAlongMuted: [String] = []) -> NoticeRules {
        var rules = NoticeRules()
        if noticeDelivery == "system" {
            rules.setStyle(.system, for: .agents)
        } else if agentNotice == "compact" {
            rules.setStyle(.strip, for: .agents)
        }
        if let whatsAppNotify { rules.set(.chats, app: "whatsapp", on: whatsAppNotify) }
        for bundleID in thinkAlongMuted { rules.set(.suggestions, app: bundleID, on: false) }
        return rules
    }
}
