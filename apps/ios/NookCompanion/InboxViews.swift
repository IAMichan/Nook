import SwiftUI
import UIKit

// MARK: The list

/// The Mac's Chats tab on the phone: WhatsApp (through the phone linked to Nook) and every other chat app Nook collects
/// on the Mac (Telegram, Messages, Slack…). With a Mac that lists `chatActions` it is the Mac's tab entirely: the views by
/// read state, one app at a time with its Chats, Status and Channels, the search through every message, the chats pinned
/// on top and the rest by day, and every chat's own actions in its menu and under a swipe. An older Mac gets the list
/// with All and Unread, as before.
struct InboxListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [String]
    @State private var query = ""
    @State private var view = InboxView.all
    /// One app's chats (`InboxChatDigest.app`), and which of its lists.
    @State private var app: String?
    @State private var kind = "chats"
    /// Groups you folded, as on the Mac.
    @State private var folded: Set<InboxGroup> = []
    @State private var confirm: InboxConfirm?
    /// ⌘F asked for search: the field shows also while the list is short.
    @Environment(\.searchFocusRequest) private var searchRequest

    private var full: Bool { client.can(CompanionFeature.chatActions) }
    private var words: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The chats of the list as it is chosen: the search's when you search (the Mac's, through every message), else the
    /// chosen app's list in the chosen view.
    private var shown: [InboxChatDigest] {
        if full, !words.isEmpty { return client.inboxFound }
        return client.inbox.filter { chat in
            view.shows(chat)
                && (app == nil ? chat.listKind == "chats" : chat.app == app && chat.listKind == kind)
                && (full || words.isEmpty || chat.name.localizedCaseInsensitiveContains(words)
                    || chat.preview.localizedCaseInsensitiveContains(words) || chat.appName.localizedCaseInsensitiveContains(words))
        }
    }

    /// The apps in the list, those with something new first, then by how many chats: as the Mac's sidebar orders them.
    private var apps: [(id: String, name: String, unread: Int)] {
        var seen: [String: (name: String, chats: Int, unread: Int)] = [:]
        for chat in client.inbox {
            var entry = seen[chat.app] ?? (chat.appName, 0, 0)
            entry.chats += 1
            if chat.listKind == "chats" { entry.unread += chat.unread > 0 ? 1 : 0 }
            seen[chat.app] = entry
        }
        return seen.sorted { a, b in
            if (a.value.unread > 0) != (b.value.unread > 0) { return a.value.unread > 0 }
            return a.value.chats != b.value.chats ? a.value.chats > b.value.chats : a.value.name < b.value.name
        }.map { ($0.key, $0.value.name, $0.value.unread) }
    }

    /// The lists the chosen app has besides its chats.
    private var kinds: [String] {
        guard let app else { return [] }
        let present = Set(client.inbox.filter { $0.app == app }.map(\.listKind))
        let all = ["chats", "status", "channels"].filter { present.contains($0) || $0 == "chats" }
        return all.count > 1 ? all : []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelHeader()
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ConnectionLine()
                    top
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
                if full && words.isEmpty {
                    ForEach(InboxGroup.sections(shown)) { section in
                        groupHeader(section)
                        if !folded.contains(section.group) { rows(section.chats) }
                    }
                } else {
                    rows(shown)
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
            // A chat that gets a message moves up instead of jumping there.
            .animation(Theme.reveal, value: shown)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await client.loadInbox() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { InboxChatView(chatID: $0) }
        .screen()
        .inboxConfirm($confirm, client: client)
        // The app's polling keeps the list current from here on (and the badge on the tab).
        .task { await client.loadInbox() }
        // The Mac's search goes through every message: asked a moment after you stop typing.
        .task(id: words) {
            guard full, !words.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await client.searchInbox(words)
        }
        .onChange(of: app) { _, _ in kind = "chats" }
    }

    @ViewBuilder
    private var top: some View {
        if !client.can(CompanionFeature.inbox) {
            WSEmptyState(symbol: "arrow.down.circle", title: String(localized: "Update Nook on your Mac"),
                         message: String(localized: "Update Nook on your Mac to read and answer your chats from your phone."))
        } else {
            if client.inboxStatus == "chatsaccess" {
                Banner(text: String(localized: "Nook cannot read the notifications on your Mac: give it Full Disk Access in System Settings."),
                       symbol: "lock")
            }
            if client.inbox.isEmpty {
                if client.phase == .connected {
                    if client.inboxStatus == "chatsoff" {
                        WSEmptyState(symbol: "bubble.left.and.bubble.right", title: String(localized: "Chats are off on your Mac"),
                                     message: String(localized: "Link WhatsApp or turn on Chats in Nook › Settings › Connections to see every chat here."))
                    } else {
                        WSEmptyState(symbol: "bubble.left.and.bubble.right", title: String(localized: "No chats yet"),
                                     message: String(localized: "New messages from WhatsApp and your other chat apps on your Mac show up here."))
                    }
                } else if client.isOffline {
                    // Nothing kept yet (a first launch away from the Mac): say so instead of an empty tab.
                    WSEmptyState(symbol: "wifi.slash", title: String(localized: "Your chats show up here"),
                                 message: String(localized: "Nothing is kept on this iPhone yet. Your chats appear once your Mac is connected, and stay readable when it is not."))
                        .appearsAfterDelay()
                }
            } else {
                if full {
                    NookSearchField(prompt: "Search chats and messages", text: $query)
                    if words.isEmpty { filters }
                } else if client.inbox.count > 8 || searchRequest.asked {
                    // Finding one among many; a short list needs no search or filter.
                    NookSearchField(prompt: "Search chats", text: $query)
                    HStack(spacing: Theme.Spacing.xs) {
                        NookFilterChip(title: String(localized: "All"), selected: view == .all) { view = .all }
                        NookFilterChip(title: String(localized: "Unread"), count: client.inbox.count(where: { $0.unread > 0 }),
                                       selected: view == .unread) { view = .unread }
                    }
                }
                if shown.isEmpty { emptyNote }
            }
        }
    }

    /// The Mac's sidebar as chips: the views by read state, then each app; with an app chosen, its Chats, Status and
    /// Channels.
    private var filters: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(InboxView.allCases, id: \.self) { option in
                        let count = option.counts ? client.inbox.count(where: { option.shows($0) && $0.listKind == "chats" }) : nil
                        NookFilterChip(title: option.title, count: count == 0 ? nil : count, selected: view == option) {
                            withAnimation(Theme.reveal) { view = option }
                        }
                    }
                    if client.inbox.contains(where: { $0.unread > 0 }) {
                        Button {
                            Haptics.tap()
                            Task {
                                for chat in client.inbox where chat.unread > 0 {
                                    await client.actInInbox(chat.id, .init(kind: .markReadInNook))
                                }
                            }
                        } label: {
                            Label("Mark all as read", systemImage: "checkmark.circle")
                                .labelStyle(.iconOnly)
                                .font(Theme.font(15))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 34, height: 30)
                        }
                        .accessibilityLabel("Mark all as read in Nook")
                    }
                }
            }
            if apps.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        NookFilterChip(title: String(localized: "Every app"), selected: app == nil) { withAnimation(Theme.reveal) { app = nil } }
                        ForEach(apps, id: \.id) { item in
                            NookFilterChip(title: item.name, count: item.unread == 0 ? nil : item.unread, selected: app == item.id) {
                                withAnimation(Theme.reveal) { app = app == item.id ? nil : item.id }
                            }
                        }
                    }
                }
            }
            if !kinds.isEmpty {
                Picker("List", selection: $kind) {
                    ForEach(kinds, id: \.self) { kind in Text(InboxView.kindTitle(kind)).tag(kind) }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var emptyNote: some View {
        Group {
            if !words.isEmpty {
                Text("No chat matches.")
            } else {
                switch view {
                case .unread: Text("Nothing unread.")
                case .readInNook: Text("No chat is read only in Nook.")
                case .read: Text("No chat is read everywhere yet.")
                case .all: Text("No chats here yet.")
                }
            }
        }
        .multilineTextAlignment(.center)
        .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
    }

    private func groupHeader(_ section: InboxGroup.Section) -> some View {
        Button {
            Haptics.tap()
            withAnimation(Theme.reveal) {
                if folded.contains(section.group) { folded.remove(section.group) } else { folded.insert(section.group) }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(section.group.title).font(Theme.TextStyle.label).foregroundStyle(Theme.textTertiary)
                Image(icon: folded.contains(section.group) ? "chevron.right" : "chevron.down")
                    .font(Theme.font(9, .bold)).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ chats: [InboxChatDigest]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                if index > 0 { NookRowSeparator() }
                OpenLink(value: chat.id) { InboxRow(chat: chat) }
                    .buttonStyle(RowPress())
                    .contextMenu {
                        if full { InboxChatActions(chat: chat, confirm: { confirm = $0 }) } else { markButton(chat) }
                    }
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
    }

    /// Read or unread by hand, as the "…" menu of a chat on an older Mac.
    @ViewBuilder
    private func markButton(_ chat: InboxChatDigest) -> some View {
        if chat.unread > 0 || chat.waitsInApp {
            Button { Task { await client.markInbox(chat.id, read: true) } } label: { Label("Mark as read", systemImage: "envelope.open") }
        } else {
            Button { Task { await client.markInbox(chat.id, read: false) } } label: { Label("Mark as unread", systemImage: "envelope.badge") }
        }
    }
}

/// The Mac's views of the Chats tab by read state (`ChatsView`): everything, something new, read in Nook but not yet in
/// the app, and read everywhere.
enum InboxView: CaseIterable {
    case all, unread, readInNook, read

    func shows(_ chat: InboxChatDigest) -> Bool {
        switch self {
        case .all: return true
        case .unread: return chat.unread > 0
        case .readInNook: return chat.unread == 0 && chat.waitsInApp
        case .read: return chat.unread == 0 && !chat.waitsInApp
        }
    }

    /// Only what waits shows its count, as on the Mac.
    var counts: Bool { self == .unread || self == .readInNook }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .unread: return String(localized: "New")
        case .readInNook: return String(localized: "Only in Nook")
        case .read: return String(localized: "Read")
        }
    }

    static func kindTitle(_ kind: String) -> LocalizedStringKey {
        switch kind {
        case "status": return "Status"
        case "channels": return "Channels"
        default: return "Chats"
        }
    }
}

/// The groups of the list, as the Mac's (`ChatsGroup`): pinned on top, then by the day of the newest message.
enum InboxGroup: Int, CaseIterable, Comparable {
    case pinned, today, yesterday, week, month, earlier

    static func < (a: InboxGroup, b: InboxGroup) -> Bool { a.rawValue < b.rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .pinned: return "Pinned"
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "This week"
        case .month: return "This month"
        case .earlier: return "Earlier"
        }
    }

    struct Section: Identifiable {
        let group: InboxGroup
        let chats: [InboxChatDigest]
        var id: Int { group.rawValue }
    }

    static func of(_ chat: InboxChatDigest, now: Date = Date(), calendar: Calendar = .current) -> InboxGroup {
        if chat.pinned == true { return .pinned }
        let date = Date(timeIntervalSince1970: chat.last)
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return .week }
        if days < 30 { return .month }
        return .earlier
    }

    /// The chats in their groups, each group in the list's own order.
    static func sections(_ chats: [InboxChatDigest], now: Date = Date()) -> [Section] {
        var byGroup: [InboxGroup: [InboxChatDigest]] = [:]
        for chat in chats { byGroup[of(chat, now: now), default: []].append(chat) }
        return allCases.compactMap { group in byGroup[group].map { Section(group: group, chats: $0) } }
    }
}

/// A chat in the list: the shared row (`ChatListRowContent`, the same as the Mac's Chats tab) with the chat's initials
/// and its app's mark, and the count of what is unread.
struct InboxRow: View {
    let chat: InboxChatDigest
    @ObservedObject private var pictures = ChatPictures.shared

    private var when: String {
        let date = Date(timeIntervalSince1970: chat.last)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : ChatDayDivider.label(date)
    }

    var body: some View {
        if WhatsAppLook.isWhatsApp(chat.app) {
            WhatsAppRow(chat: chat)
        } else {
            nookRow
        }
    }

    private var nookRow: some View {
        ChatListRowContent(name: chat.name, when: when, preview: chat.preview.isEmpty ? chat.appName : chat.preview,
                           unread: chat.unread > 0, ticks: MessageTicks(chat.ticks),
                           // Someone typing shows in place of the newest message, as on the Mac and in WhatsApp's list.
                           typing: InboxTyping.text(chat.typing ?? [])) {
            InboxAvatar(name: chat.name, app: chat.app, size: SharedMetrics.avatar, picture: pictures.image(for: chat))
        } trailing: {
            HStack(spacing: Theme.Spacing.xs) {
                // Muted and pinned, as the Mac's row marks them.
                if chat.mutedInApp == true {
                    Image(icon: "bell.slash.fill").font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel(Text("Muted"))
                }
                if chat.pinned == true || chat.pinnedInApp == true {
                    Image(icon: "pin.fill").font(Theme.font(11)).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel(Text("Pinned"))
                }
                NookCountBadge(count: chat.unread)
                    .accessibilityLabel(Text("\(chat.unread) unread"))
            }
        }
    }
}

/// A chat's initials in the person's own color (`ChatInitialsFace`, shared with the Mac), with its app's mark in the
/// app's own color in the corner.
struct InboxAvatar: View {
    let name: String
    let app: String
    var size: CGFloat = 40
    /// The chat's own picture from the Mac (`ChatPictures`); the initials while there is none.
    var picture: UIImage? = nil
    /// The app's mark on the corner; WhatsApp's own look has none.
    var showsBadge = true
    @ObservedObject private var pictures = ChatPictures.shared

    private var initials: String { Self.initials(name) }

    /// Up to two initials of a name ("#" when it has no letters), for a face without a photo.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }.map(String.init).joined()
        return letters.isEmpty ? "#" : letters.uppercased()
    }

    var body: some View {
        let style = Self.style(app)
        // The Mac's `ChatsAvatar`: the initials in the person's own color, the app as a badge on the corner.
        face
            .overlay(alignment: .bottomTrailing) {
                // The app's real icon from the Mac (the Mac's `SiteIcon` with `source`), else its mark in its color.
                Group {
                    if !showsBadge {
                        EmptyView()
                    } else if let icon = pictures.appIcon(app) {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: size * 0.46, height: size * 0.46)
                    } else {
                        Image(icon: style.symbol)
                            .font(Theme.font(size * 0.2, .bold))
                            .foregroundStyle(.white)
                            .frame(width: size * 0.42, height: size * 0.42)
                            .background(style.color, in: Circle())
                            .padding(Theme.Spacing.xxs / 2)
                            .background(Circle().fill(Theme.canvas))
                    }
                }
                .offset(x: Theme.Spacing.xs, y: Theme.Spacing.xxs)
            }
            .accessibilityHidden(true)
    }

    /// The photo when the Mac sent one, cut to a circle; else the initials in the person's own color.
    @ViewBuilder
    private var face: some View {
        if let picture {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .transition(.opacity)
        } else {
            ChatInitialsFace(name: name, initials: initials, size: size)
        }
    }

    /// Each app in its own color, so a list of many apps reads at a glance.
    static func style(_ app: String) -> (symbol: String, color: Color) {
        switch app {
        case "whatsapp": return ("phone.fill", Color(hex: 0x25D366))
        case "telegram": return ("paperplane.fill", Color(hex: 0x2AABEE))
        case "messages": return ("message.fill", Color(hex: 0x34C759))
        case "signal": return ("bubble.left.fill", Color(hex: 0x3A76F0))
        case "instagram": return ("camera.fill", Color(hex: 0xE1306C))
        case "messenger": return ("bolt.horizontal.fill", Color(hex: 0x0084FF))
        case "snapchat": return ("camera.viewfinder", Color(hex: 0xF5C400))
        case "slack": return ("number", Color(hex: 0xE01E5A))
        case "discord": return ("gamecontroller.fill", Color(hex: 0x5865F2))
        case "teams": return ("person.3.fill", Color(hex: 0x6264A7))
        case "linkedin": return ("briefcase.fill", Color(hex: 0x0A66C2))
        case "mail": return ("envelope.fill", Color(hex: 0x1A8CFF))
        case "outlook": return ("envelope.badge.fill", Color(hex: 0x0078D4))
        case "gmail": return ("envelope.fill", Color(hex: 0xEA4335))
        default: return ("bubble.left.and.bubble.right.fill", Theme.textSecondary)
        }
    }
}

// MARK: One chat

struct InboxChatView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let chatID: String
    @State private var text = ""
    @State private var sending = false
    /// The message the field answers, quoted above it until it is sent or let go.
    @State private var replyingTo: InboxLine?
    /// Your message whose info is open: who has it and who read it.
    @State private var info: InboxLine?
    /// What goes with the next message besides words.
    @State private var attachments = InboxAttachments()
    /// The sheets and questions a message or the chat opens.
    @State private var forwarding: InboxLine?
    @State private var editing: InboxLine?
    @State private var reacting: InboxLine?
    @State private var photo: InboxPhoto?
    @State private var showsInfo = false
    @State private var confirm: InboxConfirm?
    /// Older messages are being read back from the chat's app.
    @State private var loadingOlder = false

    @ObservedObject private var pictures = ChatPictures.shared
    @ObservedObject private var media = ChatMediaStore.shared
    private var chat: InboxChatDigest? { client.inbox.first { $0.id == chatID } ?? client.inboxFound.first { $0.id == chatID } }
    private var lines: [InboxLine] { client.inboxLines[chatID] ?? [] }
    /// Who is typing here now, as the Mac says it.
    private var typing: String? { InboxTyping.text(client.inboxTyping[chatID] ?? []) }
    /// A WhatsApp chat looks as WhatsApp does (`WhatsAppLook`); any other keeps Nook's look.
    private var whatsApp: Bool { WhatsAppLook.isWhatsApp(chat?.app) }
    /// The Mac's whole Chats tab (`CompanionFeature.chatActions`); an older Mac reads and answers only.
    private var full: Bool { client.can(CompanionFeature.chatActions) }
    private var can: Set<InboxAbility> { chat?.can ?? [] }

    var body: some View {
        ConversationScroll(followKey: followKey) { scroll in
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                if lines.isEmpty {
                    if client.isOffline {
                        OfflineNote(text: String(localized: "This chat is not kept on this iPhone yet. It opens once your Mac is connected."))
                            .padding(.vertical, Theme.Spacing.xxl)
                            .appearsAfterDelay()
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
                    }
                } else if full, client.inboxMore[chatID] == true {
                    olderButton(scroll)
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    let previous = index > 0 ? lines[index - 1] : nil
                    let next = index + 1 < lines.count ? lines[index + 1] : nil
                    if ChatRuns.newDay(line, after: previous) {
                        let day = Date(timeIntervalSince1970: line.date)
                        if whatsApp { WhatsAppDayPill(label: ChatDayDivider.label(day)) } else { ChatDayDivider(date: day) }
                    }
                    bubble(line, first: !ChatRuns.sameRun(previous, line), last: !ChatRuns.sameRun(line, next))
                        .id(line.id)
                }
                // WhatsApp says it in the header instead.
                if let typing, !whatsApp {
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        // Their face beside it, as beside each of their messages in a group (`ChatBubbleView`).
                        if let name = (client.inboxTyping[chatID] ?? []).first(where: { !$0.name.isEmpty })?.name {
                            ChatInitialsFace(name: name, initials: InboxAvatar.initials(name), size: 28)
                                .accessibilityHidden(true)
                        }
                        ChatTypingBubble(text: typing)
                    }
                    .transition(.opacity)
                }
                // Your messages that wait on the phone for the Mac, dimmed, until it takes them.
                let waiting = client.outbox.chatMessages(to: chatID)
                ForEach(waiting) { entry in
                    let files = (entry.request.images?.count ?? 0) + (entry.request.attachments?.count ?? 0)
                    ChatBubbleView(line: InboxLine(id: entry.id, text: entry.request.text ?? "", date: entry.queued, sender: "",
                                                   fromMe: true, attachment: files > 0 ? String(localized: "\(files) attached") : nil,
                                                   reactions: []),
                                   pending: true, whatsApp: whatsApp)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .animation(Theme.reveal, value: typing)
        } floating: {
            EmptyView()
        } dock: { scroll in
            footer(scroll)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .chatScreen(whatsApp: whatsApp)
        .sheet(item: $info) { line in
            InboxMessageInfo(line: line)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $forwarding) { line in InboxForwardSheet(chatID: chatID, line: line) }
        .sheet(item: $editing) { line in InboxEditSheet(chatID: chatID, line: line) }
        .sheet(item: $reacting) { line in
            InboxReactionPicker(current: Set(line.myReactions ?? [])) { react($0, to: line) }
        }
        .fullScreenCover(item: $photo) { item in InboxPhotoViewer(image: item.image, title: item.title) }
        .sheet(isPresented: $showsInfo) {
            if let chat { InboxInfoSheet(chat: chat, confirm: { confirm = $0 }) }
        }
        .inboxConfirm($confirm, client: client, onGone: { dismiss() })
        .task(id: chatID) {
            // Live from a Mac that sends the open chat by itself (`liveChats`): new messages and typing show at once.
            // Otherwise, or while the connection is down, asked for every few seconds.
            while !Task.isCancelled {
                if client.chatsAreLive, await client.watchChat(chatID) {
                    while !Task.isCancelled, client.chatsAreLive { try? await Task.sleep(for: .seconds(2)) }
                    continue
                }
                await client.loadInboxChat(chatID)
                // While someone types, sooner: their words and the end of their typing show without a long wait.
                try? await Task.sleep(for: .seconds(typing == nil ? 4 : 1.5))
            }
        }
        .onDisappear { Task { await client.unwatchChat(chatID) } }
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if whatsApp, let chat {
            // WhatsApp's header: the round picture, the name, and under it who is typing.
            ToolbarItem(placement: .topBarLeading) {
                Button { openInfo() } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        InboxAvatar(name: chat.name, app: chat.app, size: 36, picture: pictures.image(for: chat), showsBadge: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(chat.name).font(Theme.font(17, .semibold)).foregroundStyle(WhatsAppLook.text).lineLimit(1)
                            if let typing {
                                Text(typing).font(Theme.font(12.5)).foregroundStyle(WhatsAppLook.green).lineLimit(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!full)
                .accessibilityHint(full ? Text("Chat info") : Text(verbatim: ""))
            }
        } else {
            ToolbarItem(placement: .principal) {
                // The chat's face beside its name, as a messaging app's header; a tap opens its info.
                Button { openInfo() } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        if let chat {
                            InboxAvatar(name: chat.name, app: chat.app, size: 30, picture: pictures.image(for: chat))
                        }
                        SheetTitle(title: chat?.name ?? "", subtitle: typing ?? chat?.appName)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!full)
                .accessibilityHint(full ? Text("Chat info") : Text(verbatim: ""))
            }
        }
        if let chat {
            if full, let phone = client.inboxInfo[chat.id]?.details.first(where: { $0.key == "phone" })?.value,
               chat.group != true, let call = InboxAppLink.call(phone) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UIApplication.shared.open(call) } label: { Image(icon: "phone") }
                        .accessibilityLabel("Call")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if full {
                        Button { openInfo() } label: { Label("Chat info", systemImage: "info.circle") }
                        InboxChatActions(chat: chat, confirm: { confirm = $0 }, onUnread: { dismiss() })
                    } else if chat.unread > 0 || chat.waitsInApp {
                        Button { Task { await client.markInbox(chat.id, read: true) } } label: {
                            Label("Mark as read", systemImage: "envelope.open")
                        }
                    } else {
                        // As on the Mac, the chat closes, so that opening it again reads it.
                        Button {
                            Task {
                                await client.markInbox(chat.id, read: false)
                                dismiss()
                            }
                        } label: {
                            Label("Mark as unread", systemImage: "envelope.badge")
                        }
                    }
                } label: {
                    Image(icon: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
    }

    private func openInfo() {
        guard full, chat != nil else { return }
        Haptics.tap()
        showsInfo = true
    }

    // MARK: Messages

    /// "Older messages" at the top, as the Mac reads them back when you reach the top: from Nook, else from the chat's
    /// app. The message you read stays where it was.
    private func olderButton(_ scroll: ConversationScrollControl) -> some View {
        Button {
            guard !loadingOlder else { return }
            let anchor = lines.first?.id
            loadingOlder = true
            Task {
                await client.loadOlderInbox(chatID)
                loadingOlder = false
                if let anchor { scroll.scrollTo(anchor) }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if loadingOlder { ProgressView().controlSize(.small) } else { Image(icon: "arrow.up") }
                Text("Older messages")
            }
            .font(Theme.TextStyle.label)
            .foregroundStyle(whatsApp ? WhatsAppLook.quiet : Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background(whatsApp ? WhatsAppLook.bar : Theme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Spacing.md)
    }

    @ViewBuilder
    private func bubble(_ line: InboxLine, first: Bool, last: Bool) -> some View {
        let actionable = full && line.local != true && line.notice != true
        let image = media.image(chat: chatID, line: line)
        ChatBubbleView(line: line, first: first, last: last, whatsApp: whatsApp,
                       onInfo: line.readers?.isEmpty == false ? { info = line } : nil,
                       photo: image,
                       onPhoto: image.map { image in { photo = InboxPhoto(id: line.id, image: image, title: chat?.name ?? "") } },
                       onVote: actionable && can.contains(.vote) && line.poll != nil ? { option in vote(option, on: line) } : nil,
                       onReaction: actionable && can.contains(.react) && line.deleted != true ? { react($0, to: line) } : nil)
            .onAppear { if line.thumb != nil, full { media.want(chat: chatID, line: line, client: client) } }
            .contextMenu {
                if line.notice != true { messageMenu(line, actionable: actionable) }
            }
    }

    /// A message's menu, as the Mac's (`MessageMenuItems`): emoji, reply, copy, edit, forward, its info, delete. Each
    /// where the chat's app takes it.
    @ViewBuilder
    private func messageMenu(_ line: InboxLine, actionable: Bool) -> some View {
        let alive = line.deleted != true
        if actionable, alive, can.contains(.react) {
            Menu {
                ForEach(InboxQuickReactions.all, id: \.self) { emoji in
                    Button { react(emoji, to: line) } label: {
                        Text(verbatim: (line.myReactions ?? []).contains(emoji) ? "\(emoji) ✓" : emoji)
                    }
                }
                Button { reacting = line } label: { Label("More…", systemImage: "face.smiling") }
            } label: {
                Label("React", systemImage: "face.smiling")
            }
        }
        if chat?.canSend == true, line.local != true, alive, !full || can.contains(.reply) {
            Button { withAnimation { replyingTo = line } } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
        }
        if !line.text.isEmpty || line.attachment != nil {
            Button { UIPasteboard.general.string = line.text.isEmpty ? (line.attachment ?? "") : line.text } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        if let image = media.image(chat: chatID, line: line) {
            Button { UIPasteboard.general.image = image } label: { Label("Copy photo", systemImage: "photo") }
        }
        if actionable, alive, line.fromMe, can.contains(.edit), !line.text.isEmpty, line.poll == nil {
            Button { editing = line } label: { Label("Edit", systemImage: "pencil") }
        }
        if actionable, alive, line.poll == nil, client.inbox.contains(where: \.canSend) {
            Button { forwarding = line } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
        }
        if line.readers?.isEmpty == false {
            Button { info = line } label: { Label("Message info", systemImage: "info.circle") }
        }
        if actionable, let chat {
            Button(role: .destructive) { confirm = .deleteMessage(chat, line) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func react(_ emoji: String, to line: InboxLine) {
        Haptics.tap()
        Task { await client.actInInbox(chatID, .init(kind: .react, message: line.id, emoji: emoji)) }
    }

    private func vote(_ option: String, on line: InboxLine) {
        guard let poll = line.poll else { return }
        let choice = poll.choice(afterTapping: option)
        Task { await client.actInInbox(chatID, .init(kind: .vote, message: line.id, choices: choice)) }
    }

    /// Changes when something new comes in at the end: a message, someone typing, one of yours waiting to go.
    private var followKey: [String] {
        [lines.last?.id ?? "", typing ?? "", String(client.outbox.chatMessages(to: chatID).count)]
    }

    // MARK: Answering

    /// A chat Nook can write in gets the Mac's composer, with the message it answers in a tray above it and the pictures
    /// and file that go with it; any other chat says where to answer it, with a way to open its app on this phone.
    @ViewBuilder
    private func footer(_ scroll: ConversationScrollControl) -> some View {
        if chat?.canSend == true {
            ComposerDock(fill: whatsApp ? WhatsAppLook.wallpaper : Theme.canvas) {
                VStack(spacing: 0) {
                    if let replyingTo {
                        ComposerTray(edge: .top) { replyTray(replyingTo) }
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    InboxAttachmentTray(attachments: $attachments)
                    composer(scroll).zIndex(1)
                }
            }
        } else if let chat {
            ComposerDock(offline: .reads) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Label {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Nook can only read this chat. Answer it in \(chat.appName).")
                            // How to answer it from here next time.
                            Text("To answer from your phone, link \(chat.appName) in Nook › Settings › Chats on your Mac.")
                                .foregroundStyle(Theme.textTertiary)
                        }
                    } icon: {
                        Image(icon: "info.circle")
                    }
                    if let link = InboxAppLink.open(chat) {
                        Button { UIApplication.shared.open(link) } label: {
                            Label("Open in \(chat.appName)", systemImage: "arrow.up.forward.app")
                                .font(Theme.TextStyle.control)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(Theme.TextStyle.detail)
                .foregroundStyle(Theme.textSecondary)
                .card(padding: Theme.Spacing.lg)
            }
        }
    }

    private func replyTray(_ line: InboxLine) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Capsule().fill(line.fromMe ? Theme.mint : Theme.blue).frame(width: 3)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(line.fromMe ? String(localized: "You") : (line.sender.isEmpty ? chat?.name ?? "" : line.sender))
                    .font(Theme.TextStyle.label).foregroundStyle(line.fromMe ? Theme.mint : Theme.blue)
                Text(line.text.isEmpty ? (line.attachment ?? "") : line.text)
                    .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { withAnimation(Theme.reveal) { replyingTo = nil } } label: {
                Image(icon: "xmark").font(Theme.font(11, .bold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel reply")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func composer(_ scroll: ConversationScrollControl) -> some View {
        let photos = full && can.contains(.photo)
        let files = full && can.contains(.file)
        let submit = {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            scroll.scrollToEnd()
            send(message)
        }
        if whatsApp {
            WhatsAppComposer(text: $text, sending: sending, hasAttachments: !attachments.isEmpty, onSend: submit) {
                if photos || files {
                    InboxAttachButton(attachments: $attachments, photos: photos, files: files, tint: WhatsAppLook.quiet)
                }
            }
        } else if photos || files {
            SessionComposer(text: $text, prompt: "Message", sending: sending, allowsEmpty: !attachments.isEmpty, onSend: submit) {
                InboxAttachButton(attachments: $attachments, photos: photos, files: files)
            }
        } else {
            SessionComposer(text: $text, prompt: "Message", sending: sending, onSend: submit)
        }
    }

    /// Your own words (with what is attached), after your own tap; when they could not go the text, the quote and the
    /// attachments stay.
    private func send(_ message: String) {
        sending = true
        Haptics.tap()
        let quoted = replyingTo?.id
        let attached = attachments
        attachments = InboxAttachments()
        Task {
            let delivery = attached.isEmpty
                ? await client.sendInbox(message, to: chatID, replyTo: quoted)
                : await client.sendInbox(message, to: chatID, replyTo: quoted, images: attached.images, files: attached.files)
            switch delivery {
            case .sent:
                Haptics.success()
                if replyingTo?.id == quoted { replyingTo = nil }
                await client.loadInboxChat(chatID)
            case .waiting:
                // Kept on the phone, shown below as waiting, and sent once the Mac answers.
                if replyingTo?.id == quoted { replyingTo = nil }
            case .refused:
                text = message
                attachments = attached
            }
            sending = false
        }
    }
}

// MARK: Typing and message info

/// What a chat shows while people type, in the same words as the Mac's (`ChatTypingLine`).
enum InboxTyping {
    static func text(_ typists: [InboxTypist]) -> String? {
        guard let first = typists.first else { return nil }
        let names = typists.map(\.name).filter { !$0.isEmpty }
        if typists.count > 2 { return String(localized: "\(typists.count) people are typing…") }
        if typists.count == 2, names.count == 2 { return String(localized: "\(names[0]) and \(names[1]) are typing…") }
        let who = names.first
        switch first.kind {
        case "recording": return who.map { String(localized: "\($0) is recording audio…") } ?? String(localized: "recording audio…")
        case "uploading": return who.map { String(localized: "\($0) is sending a file…") } ?? String(localized: "sending a file…")
        default: return who.map { String(localized: "\($0) is typing…") } ?? String(localized: "typing…")
        }
    }
}

/// Your message's info, as on the Mac: how many read it, then who read it (and when), who has it, and who does not yet.
struct InboxMessageInfo: View {
    let line: InboxLine

    private var readers: [InboxReader] { line.readers ?? [] }
    private var read: [InboxReader] { readers.filter { $0.receipt == "read" } }
    private var delivered: [InboxReader] { readers.filter { $0.receipt == "delivered" } }
    private var waiting: [InboxReader] { readers.filter { $0.receipt != "read" && $0.receipt != "delivered" } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(line.text.isEmpty ? (line.attachment ?? "") : line.text)
                        .font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(4)
                } footer: {
                    Text("\(read.count) of \(readers.count) have read it")
                }
                section("Read by", read, ticks: "read")
                section("Delivered to", delivered, ticks: "delivered")
                section("Not yet", waiting, ticks: "sent")
            }
            .navigationTitle(Text("Message info"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ people: [InboxReader], ticks: String) -> some View {
        if !people.isEmpty {
            Section {
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    HStack {
                        Text(person.name).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(1)
                        Spacer(minLength: Theme.Spacing.md)
                        if let date = person.date {
                            Text(Date(timeIntervalSince1970: date), format: .dateTime.weekday(.abbreviated).hour().minute())
                                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                HStack(spacing: Theme.Spacing.xs) {
                    MessageTicksMark(ticks: MessageTicks(ticks) ?? .sent)
                    Text(title)
                }
            }
        }
    }
}
