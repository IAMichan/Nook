import SwiftUI

/// One chat in the Chats tab: a WhatsApp chat through the linked phone, or a chat collected from another app's
/// notifications.
struct ChatsEntry: Identifiable, Equatable {
    enum Origin: Equatable {
        /// The chat's JID at the linked phone.
        case whatsApp(String)
        /// The `InboxThread` id.
        case captured(String)
    }

    let id: String
    let origin: Origin
    /// The app's source id ("telegram").
    let app: String
    let name: String
    /// The newest message, with who wrote it in a group ("Jan: dinner?").
    let preview: String
    let last: Date
    let unread: Int
}

/// Every chat in one place: WhatsApp (with a linked phone) and every other chat app on this Mac whose notifications
/// Nook collects (Telegram, Instagram, Messenger, Signal, Messages…), newest first, with a filter per app and a
/// search. A chat opens on the right as bubbles; a WhatsApp chat can be answered there, any other opens in its own app.
/// Collecting is turned on in Settings › Connections › On your Mac › Chats.
struct ChatsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @State private var selection: String?
    /// One app's chats only (its source id), or all.
    @State private var filter: String?
    @State private var query = ""

    /// Unread messages in every chat, for the dot on the tab.
    @MainActor
    static var unread: Int {
        let link = WhatsAppLink.shared
        return ChatCaptureService.shared.inbox.totalUnread + (link.isConnected ? link.inbox.visibleUnread(filters: link.filters) : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if capture.status == .needsAccess { accessBar }
            if all.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
                    list.frame(width: 290)
                    if let current {
                        ChatsDetail(entry: current, capture: capture, whatsApp: whatsApp)
                            .id(current.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selection) { _, id in
            // Reading a collected chat here is reading it; a WhatsApp chat is only read by what you do with it.
            guard let id, let entry = all.first(where: { $0.id == id }), case .captured(let thread) = entry.origin else { return }
            capture.markRead(thread)
        }
    }

    // MARK: The chats

    /// Every chat, newest first. Of WhatsApp every chat you did not hide, quiet groups included: they are all here.
    private var all: [ChatsEntry] {
        var entries: [ChatsEntry] = []
        if whatsApp.isConnected {
            for conversation in whatsApp.inbox.sorted where !whatsApp.filters.ignored.contains(conversation.id) {
                let preview = conversation.messages.last.map { message in
                    let text = AppModel.whatsAppFileLabel(message.media) ?? AppModel.whatsAppText(message)
                    let who = message.fromMe ? tr("chat.you") : (conversation.isGroup ? message.senderName : "")
                    return who.isEmpty ? text : "\(who): \(text)"
                } ?? ""
                entries.append(ChatsEntry(id: "wa|" + conversation.id, origin: .whatsApp(conversation.id), app: "whatsapp",
                                          name: conversation.name, preview: preview, last: conversation.lastActivity,
                                          unread: conversation.unread))
            }
        }
        for thread in capture.inbox.sorted {
            let preview = thread.messages.last.map { $0.sender.isEmpty ? $0.text : "\($0.sender): \($0.text)" } ?? ""
            entries.append(ChatsEntry(id: thread.id, origin: .captured(thread.id), app: thread.app, name: thread.name,
                                      preview: preview, last: thread.last, unread: thread.unread))
        }
        return entries.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
    }

    private var shown: [ChatsEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return all.filter { entry in
            (filter == nil || entry.app == filter)
                && (needle.isEmpty || entry.name.localizedCaseInsensitiveContains(needle) || entry.preview.localizedCaseInsensitiveContains(needle))
        }
    }

    /// The chat on the right: the one you picked, else the newest.
    private var current: ChatsEntry? {
        let visible = shown
        return visible.first { $0.id == selection } ?? visible.first
    }

    /// The apps that have chats here, the busiest first.
    private var apps: [String] {
        let counts = Dictionary(grouping: all, by: \.app).mapValues(\.count)
        return counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textTertiary)
                TextField(tr("chats.search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                // WhatsApp's unread marks belong to the phone: a chat there is read by what you do with it.
                if capture.inbox.totalUnread > 0 {
                    ToolbarIconButton("checkmark.circle", tr("chats.markAllRead")) { capture.markAllRead() }
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 30)
            .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control)

            if apps.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ChatsFilterChip(title: tr("chats.filter.all"), app: nil, selected: filter == nil) { filter = nil }
                        ForEach(apps, id: \.self) { id in
                            ChatsFilterChip(title: MessagingApps.app(id: id)?.name ?? id, app: id, selected: filter == id) {
                                filter = filter == id ? nil : id
                            }
                        }
                    }
                }
            }

            ScrollView {
                LazyVStack(spacing: NookTheme.Spacing.xxs) {
                    ForEach(shown) { entry in
                        ChatsRow(entry: entry, selected: entry.id == current?.id) { selection = entry.id }
                    }
                }
            }
            if shown.isEmpty {
                Text(tr("chats.noMatch"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, NookTheme.Spacing.xl)
            }
            if !capture.enabled {
                // Only WhatsApp so far: the other chat apps are one switch away.
                SmallGhostButton(title: tr("chats.addMore")) { app.openSettings(section: .connections) }
            }
        }
    }

    // MARK: Nothing yet

    private var empty: some View {
        VStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "tray.full")
                .font(NookTheme.font(30))
                .foregroundStyle(NookTheme.textTertiary)
            Text(capture.enabled ? tr("chats.waiting.title") : tr("chats.empty.title"))
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
            Text(capture.enabled ? tr("chats.waiting.detail") : tr("chats.empty.detail"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            if !capture.enabled {
                NookPrimaryButton(title: tr("chats.empty.setup"), symbol: "gearshape") { app.openSettings(section: .connections) }
                    .fixedSize()
                    .padding(.top, NookTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// macOS keeps its notifications behind Full Disk Access.
    private var accessBar: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "lock.fill")
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.amber)
            Text(tr("chats.capture.needsAccess"))
                .font(NookTheme.font(12.5, .medium))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
            Spacer(minLength: NookTheme.Spacing.sm)
            NookNoticeActions(primary: NookNoticeAction(tr("chats.capture.grant")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            })
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
    }
}

/// An app in the filter row: its icon and name.
private struct ChatsFilterChip: View {
    let title: String
    let app: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if let app {
                    SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 13, source: app)
                }
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 24)
            .background(Capsule().fill(selected ? NookTheme.smoke : (hovering ? NookTheme.rowHover : Color.clear)))
            .overlay(Capsule().stroke(selected ? NookTheme.line2 : NookTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A chat in the list: its app's icon, its name, when and the newest message, and how many you have not read.
private struct ChatsRow: View {
    let entry: ChatsEntry
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var when: String {
        Calendar.current.isDateInToday(entry.last) ? Self.time.string(from: entry.last)
            : ChatTimeline.dayLabel(entry.last, locale: Locale(identifier: I18n.shared.currentLanguage.rawValue))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 26, source: entry.app)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(entry.name)
                            .font(NookTheme.font(13, entry.unread > 0 ? .semibold : .medium))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.xs)
                        Text(when)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(entry.unread > 0 ? NookTheme.amber : NookTheme.textTertiary)
                            .fixedSize()
                    }
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(entry.preview)
                            .font(NookTheme.font(12))
                            .foregroundStyle(entry.unread > 0 ? NookTheme.textStrong : NookTheme.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.xs)
                        if entry.unread > 0 {
                            Text("\(entry.unread)")
                                .font(NookTheme.font(10.5, .bold))
                                .foregroundStyle(NookTheme.ink)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(NookTheme.amber))
                        }
                    }
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(NookTheme.rowFill(selected: selected, hovering: hovering)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(MessagingApps.app(id: entry.app)?.name ?? entry.app), \(entry.name): \(entry.preview)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chat on the right: who and which app on top, the messages as bubbles, and how to answer below.
private struct ChatsDetail: View {
    let entry: ChatsEntry
    @ObservedObject var capture: ChatCaptureService
    @ObservedObject var whatsApp: WhatsAppLink
    @EnvironmentObject private var app: AppModel
    @State private var reply = ""
    @State private var notice: String?
    @State private var sending = false
    @FocusState private var replyFocused: Bool

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var appName: String { MessagingApps.app(id: entry.app)?.name ?? entry.app }

    private var whatsAppChat: String? {
        if case .whatsApp(let jid) = entry.origin { return jid }
        return nil
    }

    private var bubbles: [ChatBubble] {
        switch entry.origin {
        case .whatsApp(let jid):
            return whatsApp.inbox.conversations[jid].map { AppModel.whatsAppBubbles($0) } ?? []
        case .captured(let id):
            return (capture.inbox.threads[id]?.messages ?? []).map { message in
                ChatBubble(id: message.id, text: message.text, time: Self.time.string(from: message.date), date: message.date,
                           sender: message.sender)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            header
            ChatTranscript(bubbles: bubbles, contact: entry.name, fills: true,
                           onOpen: { open($0) }, onZoom: { open($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(NookTheme.Spacing.lg)
        .cardBackground(NookTheme.surface, stroke: NookTheme.hairline, radius: NookTheme.Radius.panel)
        .task(id: entry.id) { await loadWhatsApp() }
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 22, source: entry.app)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(whatsAppChat == nil ? tr("chats.fromNotifications", appName) : appName)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if let chat = whatsAppChat {
                ToolbarIconButton("sparkles", tr("whatsapp.card.nook")) { app.askNookAboutWhatsApp(chat, name: entry.name) }
                if entry.unread > 0 {
                    ToolbarIconButton("checkmark.circle", tr("whatsapp.card.read")) { whatsApp.markRead(chat) }
                }
            } else if case .captured(let id) = entry.origin {
                ToolbarIconButton("trash", tr("chats.remove")) { capture.remove(id) }
            }
            ToolbarIconButton("arrow.up.forward.app", tr("chats.openApp", appName)) { app.openChatApp(entry.app) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let notice {
            Text(notice)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(2)
        }
        if let chat = whatsAppChat {
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField(tr("whatsapp.card.answer", entry.name), text: $reply, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1...4)
                    .focused($replyFocused)
                    .onSubmit { send(to: chat) }
                    .disabled(sending)
                NookIconButton(systemName: "arrow.up", label: tr("chats.send"), filled: true, size: 28) { send(to: chat) }
                    .disabled(sending || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(tr("chats.send"))
            }
            .padding(.leading, NookTheme.Spacing.md)
            .padding(.trailing, NookTheme.Spacing.xs)
            .padding(.vertical, NookTheme.Spacing.xs)
            .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.sheet)
        } else {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("chats.replyInApp", appName))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: NookTheme.Spacing.sm)
                SmallGhostButton(title: tr("chats.openApp", appName)) { app.openChatApp(entry.app) }
            }
        }
    }

    /// Your answer goes to the chat as typed, after your own Return or click; when it fails the text stays.
    private func send(to chat: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        notice = tr("whatsapp.card.sending")
        Task { @MainActor in
            defer { sending = false }
            do {
                try await app.sendWhatsAppFromChats(text, chat: chat)
                reply = ""
                notice = nil
                replyFocused = true
            } catch {
                notice = tr("whatsapp.card.notSent", error.localizedDescription)
            }
        }
    }

    /// A file in a WhatsApp chat opens in Quick Look; a collected chat has no files.
    private func open(_ bubble: ChatBubble) {
        guard let chat = whatsAppChat, bubble.attachment != nil else { return }
        notice = tr("whatsapp.file.opening", bubble.attachment ?? "")
        Task { @MainActor in
            do {
                try await app.openWhatsAppFile(bubble, chat: chat)
                notice = nil
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Older messages and the newest photos of a WhatsApp chat, as its card fetches them.
    private func loadWhatsApp() async {
        guard let chat = whatsAppChat else { return }
        _ = await whatsApp.loadHistory(chat)
        guard let conversation = whatsApp.inbox.conversations[chat] else { return }
        let wanted = conversation.messages.filter { AppModel.whatsAppPreviews($0.media) }.suffix(AppModel.whatsAppPreviewCount)
            .filter { whatsApp.preview($0.id) == nil }.map(\.id)
        if !wanted.isEmpty { _ = await whatsApp.loadPreviews(wanted, chat: chat) }
    }
}
