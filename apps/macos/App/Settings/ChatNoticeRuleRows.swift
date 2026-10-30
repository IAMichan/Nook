import SwiftUI

/// What a chat app does in Nook, the same rows for every app in its sheet (Settings › Chats): its chats in the Chats tab,
/// its new messages in the notch, which kinds of chat stay quiet, every chat on its own (louder or quieter than its kind,
/// or hidden), and whether answering reads the chat in the app. WhatsApp had these alone; every app has them now
/// (`ChatNoticeRules`).
struct ChatAppNoticeRows: View {
    let app: String
    let setCollecting: (Bool) -> Void
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = ChatNoticeRulesStore.shared

    private var name: String { MessagingApps.app(id: app)?.name ?? app }

    private var notify: Binding<Bool> {
        Binding(get: { settings.noticeRules.isOn(.chats, app: app) }, set: { settings.noticeRules.set(.chats, app: app, on: $0) })
    }

    var body: some View {
        // A linked phone brings WhatsApp's chats by itself (its own switch, with its accounts): only the others are
        // collected and so have one here.
        if app != capture.whatsAppGatewayBridge.app {
            SettingToggle(tr("chats.apps.showInChats", name), detail: tr("chats.manage.showDetail"),
                          isOn: Binding(get: { capture.enabled && capture.sources.isOn(app) }, set: { on in
                              capture.setSource(app, on: on)
                              if on, !capture.enabled { setCollecting(true) }
                          }))
        }
        SettingToggle(tr("chats.manage.notify"), detail: tr("chats.manage.notifyDetail", name), isOn: notify)
        if notify.wrappedValue {
            ForEach(ChatNoticeRules.kinds(of: app), id: \.self) { kind in
                SettingToggle(tr(Self.kindTitle(kind)), detail: tr(Self.kindDetail(kind)),
                              isOn: Binding(get: { store.rules.quietKinds(for: app).contains(kind) },
                                            set: { store.setQuiet($0, kind: kind, app: app) }))
            }
            ChatModeList(app: app)
        }
        SettingToggle(tr("whatsapp.settings.markRead"), detail: tr("chats.rules.markReadDetail", name),
                      isOn: Binding(get: { store.rules.readsOnReply(app) }, set: { store.setReadsOnReply($0, app: app) }))
    }

    private static func kindTitle(_ kind: ChatKind) -> String {
        switch kind {
        case .group: return "whatsapp.settings.muteGroups"
        case .status: return "whatsapp.settings.muteStatus"
        case .channel: return "whatsapp.settings.muteChannels"
        case .person: return "whatsapp.kind.person"
        }
    }

    private static func kindDetail(_ kind: ChatKind) -> String {
        switch kind {
        case .group: return "whatsapp.settings.muteGroupsDetail"
        case .status: return "whatsapp.settings.muteStatusDetail"
        case .channel: return "whatsapp.settings.muteChannelsDetail"
        case .person: return "whatsapp.kind.person"
        }
    }
}

/// Every chat of one app with its own choice: automatic (the rule of its kind), always, or never. Hidden chats can come
/// back one by one. Every linked account's chats, each on its own.
struct ChatModeList: View {
    let app: String
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var store = ChatNoticeRulesStore.shared
    @State private var query = ""
    @State private var open = false

    /// The app's chats Nook has, newest first, with where each is while the app has more than one account.
    private var chats: [InboxThread] {
        capture.inbox.sorted.filter { $0.app == app }
    }

    private var shown: [InboxThread] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return chats.filter { !store.rules.isHidden($0.id) }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// The app's hidden chats, by name where Nook still has the chat.
    private var hidden: [(id: String, name: String)] {
        let names = Dictionary(chats.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return store.rules.hidden.filter { id in
            names[id] != nil || id.hasPrefix(app + "|") || id.hasPrefix(ChatInbox.key(app: app, id: ""))
        }.sorted().map { ($0, names[$0] ?? Self.fallbackName($0)) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if chats.isEmpty {
                SettingNote(tr("whatsapp.settings.noChats"))
            } else {
                NookSearchField(prompt: tr("whatsapp.settings.chatSearch"), text: $query, style: .inline)
                ForEach(shown) { thread in row(thread) }
            }
            if !hidden.isEmpty {
                Text(tr("whatsapp.settings.hidden"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.top, NookTheme.Spacing.sm)
                ForEach(hidden, id: \.id) { chat in
                    HStack(spacing: NookTheme.Spacing.sm) {
                        ChatPersonBadge(name: chat.name, size: 22)
                        Text(chat.name).lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        Button(tr("whatsapp.settings.showAgain")) { store.setHidden(false, chat: chat.id) }
                            .controlSize(.small)
                    }
                }
            }
        } label: {
            SettingLabel(tr("whatsapp.settings.perChat"), hint: tr("whatsapp.settings.perChatDetail"))
        }
    }

    private func row(_ thread: InboxThread) -> some View {
        let kind = thread.noticeKind
        let detail = [tr("whatsapp.kind.\(kind.rawValue)"), thread.account].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: NookTheme.Spacing.sm) {
            ChatPersonBadge(name: thread.name, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.name).lineLimit(1)
                Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            Picker("", selection: Binding(get: { store.rules.mode(for: thread.id) }, set: { store.setMode($0, for: thread.id) })) {
                Text(tr("whatsapp.mode.automatic")).tag(ChatMode.automatic)
                Text(tr("whatsapp.mode.loud")).tag(ChatMode.loud)
                Text(tr("whatsapp.mode.muted")).tag(ChatMode.muted)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .help(tr("whatsapp.mode.help", store.rules.kindIsQuiet(kind, app: app) ? tr("whatsapp.mode.muted") : tr("whatsapp.mode.loud")))
        }
        .padding(.vertical, 1)
    }

    /// A hidden chat Nook no longer holds: its number for a linked phone's WhatsApp chat, else what its id says.
    private static func fallbackName(_ id: String) -> String {
        if let jid = id.split(separator: "#", maxSplits: 1).last.map(String.init).map({ WAChatKey.split($0).jid }), id.contains("#") {
            return WAJID.displayNumber(jid)
        }
        return id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? id
    }
}
