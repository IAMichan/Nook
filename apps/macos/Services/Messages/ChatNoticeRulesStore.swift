import Foundation
import Combine

/// The notice rules every chat app follows (`ChatNoticeRules`), kept in the user defaults and chosen in Settings › Chats,
/// on a chat's card (Quiet, Hide) and in the Chats tab. The first launch with them takes over what Settings › WhatsApp
/// kept before (`WAFilters`), for every linked account. WhatsApp's link still sorts its gateway's messages by them
/// (`filters(account:)`): a hidden chat is not even kept there.
@MainActor
final class ChatNoticeRulesStore: ObservableObject {
    static let shared = ChatNoticeRulesStore()

    @Published private(set) var rules: ChatNoticeRules

    private static let key = "chats.noticeRules.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let kept = try? JSONDecoder().decode(ChatNoticeRules.self, from: data) {
            rules = kept
        } else {
            rules = Self.fromWhatsApp(defaults)
            save()
        }
    }

    /// Changes the rules, saves them, and passes them on to every WhatsApp account.
    func change(_ change: (inout ChatNoticeRules) -> Void) {
        var next = rules
        change(&next)
        guard next != rules else { return }
        rules = next
        save()
        for link in WhatsAppAccounts.shared.links { link.applyNoticeRules() }
    }

    func setMode(_ mode: ChatMode, for chat: String) { change { $0.setMode(mode, for: chat) } }

    func setHidden(_ hide: Bool, chat: String) { change { $0.setHidden(hide, chat: chat) } }

    func setQuiet(_ quiet: Bool, kind: ChatKind, app: String) { change { $0.setQuiet(quiet, kind: kind, app: app) } }

    func setReadsOnReply(_ on: Bool, app: String) { change { $0.setReadsOnReply(on, app: app) } }

    /// What one WhatsApp account sorts its gateway's messages by: the rules of its own chats, by their JIDs there.
    func filters(account: String) -> WAFilters {
        var filters = WAFilters()
        let kinds = rules.quietKinds(for: "whatsapp")
        filters.muteGroups = kinds.contains(.group)
        filters.muteStatus = kinds.contains(.status)
        filters.muteChannels = kinds.contains(.channel)
        for id in rules.hidden {
            if let jid = Self.whatsAppJID(id, account: account) { filters.ignored.insert(jid) }
        }
        for (id, mode) in rules.modes {
            guard let jid = Self.whatsAppJID(id, account: account) else { continue }
            filters.setMode(WAChatMode(mode), for: jid)
        }
        return filters
    }

    /// The JID of a WhatsApp chat id in the shared inbox ("whatsapp#<chat key>") when it is one of this account's.
    static func whatsAppJID(_ id: String, account: String) -> String? {
        let prefix = ChatInbox.key(app: "whatsapp", id: "")
        guard id.hasPrefix(prefix) else { return nil }
        let (owner, jid) = WAChatKey.split(String(id.dropFirst(prefix.count)))
        return owner == account ? jid : nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.key) }
    }

    /// What Settings › WhatsApp kept, as rules for every app: its choices held for every linked account.
    private static func fromWhatsApp(_ defaults: UserDefaults) -> ChatNoticeRules {
        let accounts = [""] + WhatsAppSettings.accounts.map(\.id)
        return ChatNoticeRules.migrated(
            muteGroups: defaults.object(forKey: "whatsappMuteGroups") as? Bool ?? true,
            muteStatus: defaults.object(forKey: "whatsappMuteStatus") as? Bool ?? true,
            muteChannels: defaults.object(forKey: "whatsappMuteChannels") as? Bool ?? true,
            ignored: Set(defaults.stringArray(forKey: "whatsappIgnored") ?? []),
            modes: defaults.dictionary(forKey: "whatsappChatModes") as? [String: String] ?? [:],
            readsOnReply: defaults.object(forKey: "whatsappMarkRead") as? Bool ?? true,
            ids: { jid in accounts.map { ChatInbox.key(app: "whatsapp", id: WAChatKey.make(WAJID.normalized(jid), account: $0)) } })
    }
}

extension WAChatMode {
    init(_ mode: ChatMode) {
        switch mode {
        case .automatic: self = .automatic
        case .loud: self = .loud
        case .muted: self = .muted
        }
    }
}

extension ChatMode {
    init(_ mode: WAChatMode) {
        switch mode {
        case .automatic: self = .automatic
        case .loud: self = .loud
        case .muted: self = .muted
        }
    }
}
