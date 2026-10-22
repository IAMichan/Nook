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
    /// The newest message is yours: how far it got (sent, delivered, read). Nil for theirs, and for every chat collected
    /// from notifications, which only ever show what came in.
    var ticks: BubbleTicks? = nil
}

/// What the Chats tab opens on when another place sends you there: one app's chats, one chat, or a search.
struct ChatsFocus: Equatable {
    /// The `ChatsEntry` id to select.
    var chat: String?
    /// The app's source id to filter on.
    var app: String?
    var query = ""
}

/// Every chat in one place: WhatsApp (with a linked phone) and every other chat app on this Mac whose notifications
/// Nook collects (Telegram, Instagram, Messenger, Signal, Messages…), in groups (unread first, then by day) that fold
/// shut, with a filter per app and a search. A chat opens on the right as bubbles; a WhatsApp chat can be answered there, any other opens in its own app.
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
    /// The groups folded shut (a click on their header); a search shows every group open.
    @State private var collapsed: Set<ChatsGroup> = []
    @AppStorage("nook.chats.listWidth") private var listWidth = PanelLayout.chatsList
    @State private var totalWidth: Double = 0

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
                // The same split as the Agents tab: a list you can widen, a line, and the open chat beside it.
                HStack(alignment: .top, spacing: 0) {
                    list
                        .padding(.trailing, NookTheme.Spacing.xs)
                        .resizablePanel(width: $listWidth, defaultWidth: PanelLayout.chatsList, minimum: PanelLayout.minimumList,
                                        available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                                        edge: .trailing, divider: true)
                    Group {
                        if let current {
                            ChatsDetail(entry: current, capture: capture, whatsApp: whatsApp)
                                .id(current.id)
                        } else {
                            // Nothing matches the search: the list says so, this side stays quiet.
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(NookTheme.font(26, .light))
                                .foregroundStyle(NookTheme.textMuted)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, NookTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .onAppear { takeFocus() }
        .onChange(of: viewModel.chatsFocus) { _, _ in takeFocus() }
        .onChange(of: selection) { _, id in
            // Reading a collected chat here is reading it; a WhatsApp chat is only read by what you do with it.
            guard let id, let entry = all.first(where: { $0.id == id }), case .captured(let thread) = entry.origin else { return }
            capture.markRead(thread)
        }
    }

    /// Shows what "@chats …" or "@open chat …" asked for.
    private func takeFocus() {
        guard let focus = viewModel.chatsFocus else { return }
        viewModel.chatsFocus = nil
        filter = focus.app
        query = focus.query
        selection = focus.chat
        collapsed = []
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
                let newest = conversation.messages.last
                let ticks = newest.flatMap { $0.fromMe ? $0.receipt.map(AppModel.bubbleTicks) : nil }
                entries.append(ChatsEntry(id: "wa|" + conversation.id, origin: .whatsApp(conversation.id), app: "whatsapp",
                                          name: conversation.name, preview: preview, last: conversation.lastActivity,
                                          unread: conversation.unread, ticks: ticks))
            }
            // Every other chat on the phone, also the ones that wrote nothing since Nook was linked: their messages load
            // when one is opened.
            var listed = Set(entries.map(\.id))
            for chat in whatsApp.knownChats
            where WAJID.kind(chat.jid) != .status && !whatsApp.filters.ignored.contains(chat.jid) {
                let id = "wa|" + chat.jid
                guard listed.insert(id).inserted else { continue }
                entries.append(ChatsEntry(id: id, origin: .whatsApp(chat.jid), app: "whatsapp",
                                          name: chat.name.isEmpty ? WAJID.displayNumber(chat.jid) : chat.name,
                                          preview: "", last: chat.last, unread: 0))
            }
        }
        for thread in capture.inbox.sorted where capture.sources.isOn(thread.app) {
            let preview = thread.messages.last.map { $0.sender.isEmpty ? $0.text : "\($0.sender): \($0.text)" } ?? ""
            entries.append(ChatsEntry(id: thread.id, origin: .captured(thread.id), app: thread.app, name: thread.name,
                                      preview: preview, last: thread.last, unread: thread.unread))
        }
        return entries.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
    }

    /// The chats that match the filter and the search, in the list's order: group by group, newest first in each.
    private var shown: [ChatsEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let now = Date()
        return all.filter { entry in
            (filter == nil || entry.app == filter)
                && (needle.isEmpty || entry.name.localizedCaseInsensitiveContains(needle) || entry.preview.localizedCaseInsensitiveContains(needle))
        }
        .map { (entry: $0, group: ChatsGroup.of($0, now: now)) }
        .sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            return a.entry.last != b.entry.last ? a.entry.last > b.entry.last : a.entry.id < b.entry.id
        }
        .map(\.entry)
    }

    /// The shown chats per group, in order; empty groups left out.
    private var sections: [ChatsSection] {
        let now = Date()
        var result: [ChatsSection] = []
        for entry in shown {
            let group = ChatsGroup.of(entry, now: now)
            if result.last?.group == group { result[result.count - 1].entries.append(entry) }
            else { result.append(ChatsSection(group: group, entries: [entry])) }
        }
        return result
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The chat on the right: the one you picked, else the newest.
    private var current: ChatsEntry? {
        let visible = shown
        return visible.first { $0.id == selection } ?? visible.first
    }

    /// The apps that have chats here, the busiest first, and the one filtered on even when it has none yet.
    private var apps: [String] {
        let counts = Dictionary(grouping: all, by: \.app).mapValues(\.count)
        let busy = counts.keys.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 }
        guard let filter, !busy.contains(filter) else { return busy }
        return busy + [filter]
    }

    /// The list's title, as the Agents tab has it: how many messages wait for you, and the list's two actions.
    private var listHeader: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(tr("tab.chats"))
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            let unread = Self.unread
            if unread > 0 {
                Text("\(unread)")
                    .font(NookTheme.font(10.5, .bold))
                    .foregroundStyle(NookTheme.ink)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(NookTheme.amber))
                    .accessibilityLabel("\(tr("chats.group.unread")): \(unread)")
            }
            Spacer(minLength: NookTheme.Spacing.xs)
            // WhatsApp's unread marks belong to the phone: a chat there is read by what you do with it.
            if capture.inbox.totalUnread > 0 {
                ToolbarIconButton("checkmark.circle", tr("chats.markAllRead")) { capture.markAllRead() }
            }
            ToolbarIconButton("plus", tr("chats.addSource")) { app.openSettings(section: .chats) }
        }
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.xxs)
    }

    private var searchField: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textTertiary)
            TextField(tr("chats.search"), text: $query)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
            if !query.isEmpty {
                ToolbarIconButton("xmark.circle.fill", tr("button.clear"), height: 20, width: 20) { query = "" }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .frame(height: 30)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            listHeader
            searchField

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
                    let selected = current?.id
                    let groups = sections
                    ForEach(groups) { section in
                        let open = searching || !collapsed.contains(section.group)
                        ChatsGroupHeader(title: section.group.title, count: section.entries.count, open: open,
                                         first: section.group == groups.first?.group) {
                            if collapsed.contains(section.group) { collapsed.remove(section.group) }
                            else { collapsed.insert(section.group) }
                        }
                        .disabled(searching)
                        if open {
                            ForEach(section.entries) { entry in
                                ChatsRow(entry: entry, selected: entry.id == selected) { selection = entry.id }
                            }
                        }
                    }
                }
            }
            if shown.isEmpty {
                ListEmptyNote(tr("chats.noMatch"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, NookTheme.Spacing.xl)
            }
            if !capture.enabled {
                // Only WhatsApp so far: the other chat apps are one switch away.
                SmallGhostButton(title: tr("chats.addMore")) { app.openSettings(section: .chats) }
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
                // Every chat app is on by default: one click starts collecting, Settings is for choosing.
                HStack(spacing: NookTheme.Spacing.sm) {
                    NookPrimaryButton(title: tr("chats.empty.turnOn"), symbol: "tray.and.arrow.down") { turnOn() }
                    NookGhostButton(title: tr("chats.empty.setup"), symbol: "gearshape") { app.openSettings(section: .chats) }
                }
                .fixedSize()
                .padding(.top, NookTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func turnOn() {
        capture.enabled = true
        if let source = app.connectors.source(id: ChatInboxConnector.sourceID) { app.connectors.refresh(source) }
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

/// A group of the list: the chats waiting for you first, then by when they last moved.
enum ChatsGroup: Int, Comparable, CaseIterable {
    case unread, today, yesterday, week, month, earlier

    static func < (lhs: ChatsGroup, rhs: ChatsGroup) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .unread: return tr("chats.group.unread")
        case .today: return tr("chats.group.today")
        case .yesterday: return tr("chats.group.yesterday")
        case .week: return tr("chats.group.week")
        case .month: return tr("chats.group.month")
        case .earlier: return tr("chats.group.earlier")
        }
    }

    /// Where a chat goes: unread chats on top whatever their age, the others by their newest message.
    static func of(_ entry: ChatsEntry, now: Date, calendar: Calendar = .current) -> ChatsGroup {
        if entry.unread > 0 { return .unread }
        let today = calendar.startOfDay(for: now)
        if entry.last >= today { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), entry.last >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), entry.last >= week { return .week }
        if let month = calendar.date(byAdding: .day, value: -30, to: today), entry.last >= month { return .month }
        return .earlier
    }
}

/// One group of the list and its chats, newest first.
struct ChatsSection: Identifiable {
    let group: ChatsGroup
    var entries: [ChatsEntry]
    var id: ChatsGroup { group }
}

/// A group's title above its chats, with how many there are; a click folds it shut or open.
private struct ChatsGroupHeader: View {
    let title: String
    let count: Int
    let open: Bool
    /// The top group sits right under the filters; the others get room above.
    let first: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(8.5, .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                Text(title.uppercased())
                    .font(NookTheme.font(10.5, .semibold))
                    .tracking(0.6)
                    .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                Spacer(minLength: NookTheme.Spacing.xs)
                Text("\(count)")
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.top, first ? NookTheme.Spacing.xxs : NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.reveal, value: open)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(.isHeader)
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
        // A chat on the phone whose last message the gateway did not date.
        guard entry.last > .distantPast else { return "" }
        return Calendar.current.isDateInToday(entry.last) ? Self.time.string(from: entry.last)
            : ChatTimeline.dayLabel(entry.last, locale: Locale(identifier: I18n.shared.currentLanguage.rawValue))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                ChatsAvatar(name: entry.name, app: entry.app, size: 34)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
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
                        if let ticks = entry.ticks { TicksView(ticks: ticks) }
                        // A chat on the phone that wrote nothing since Nook was linked: its messages load when opened.
                        Text(entry.preview.isEmpty ? tr("chats.row.load") : entry.preview)
                            .font(NookTheme.font(12))
                            .foregroundStyle(entry.unread > 0 ? NookTheme.textStrong : NookTheme.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.xs)
                        if entry.unread > 0 {
                            Text("\(entry.unread)")
                                .font(NookTheme.font(10.5, .bold))
                                .foregroundStyle(NookTheme.ink)
                                .padding(.horizontal, NookTheme.Spacing.sm)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(NookTheme.amber))
                                .fixedSize()
                        }
                    }
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(MessagingApps.app(id: entry.app)?.name ?? entry.app), \(entry.name): \(entry.preview)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Who a chat is with: their initials on a tint of their own (the same color their name has in a group's bubbles), with
/// the app the chat is in as a small badge on the corner.
private struct ChatsAvatar: View {
    let name: String
    let app: String
    let size: CGFloat

    private static let colors: [Color] = [NookTheme.mint, NookTheme.blue, NookTheme.violet, NookTheme.music]

    private var tint: Color { Self.colors[ChatTimeline.colorIndex(for: name, count: Self.colors.count)] }

    var body: some View {
        Circle()
            .fill(tint.opacity(0.16))
            .overlay(Circle().stroke(tint.opacity(0.28), lineWidth: 1))
            .overlay(
                Text(WAJID.initials(name))
                    .font(NookTheme.rounded(size * 0.36, .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: size * 0.42, source: app)
                    .padding(NookTheme.Spacing.xxs / 2)
                    .background(Circle().fill(NookTheme.canvas))
                    .offset(x: NookTheme.Spacing.xs, y: NookTheme.Spacing.xxs)
            }
            .accessibilityHidden(true)
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
    @State private var drafting = false
    /// The menu "@" opens above the field, as in Nook's own chat: "@nook" and ready-made requests.
    @StateObject private var menu = ComposerModel()
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
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, NookTheme.Spacing.md)
            Rectangle().fill(NookTheme.hairline).frame(height: 1)
            ChatTranscript(bubbles: bubbles, contact: entry.name, fills: true,
                           onOpen: { open($0) }, onZoom: { open($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) { footer }
                .padding(.top, NookTheme.Spacing.md)
        }
        .task(id: entry.id) { await loadWhatsApp() }
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            ChatsAvatar(name: entry.name, app: entry.app, size: 32)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
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

    /// "@nook …" at the start of the field: Nook writes the message instead of sending what is typed.
    private var asksNook: Bool { ChatDraft.instruction(in: reply) != nil }

    /// One field for every chat: what you type goes to a WhatsApp chat, or is copied for the app of any other chat;
    /// "@nook …" lets Nook write the message first, into this field, for you to read before it goes anywhere.
    @ViewBuilder
    private var footer: some View {
        if let notice {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                if drafting || sending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "info.circle")
                        .font(NookTheme.font(10.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                Text(notice)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            .transition(.opacity)
        }
        if menu.isOpen {
            ComposerSuggestionList(model: menu, tint: NookTheme.iris) { choose($0) }
        }
        HStack(spacing: NookTheme.Spacing.sm) {
            TextField(whatsAppChat == nil ? tr("chats.reply.copyPrompt", entry.name) : tr("chats.reply.prompt", entry.name),
                      text: $reply, axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1...6)
                .focused($replyFocused)
                .onSubmit { menu.isOpen ? chooseSelected() : submit() }
                .onKeyPress(.upArrow) { () -> KeyPress.Result in moveInMenu(-1) }
                .onKeyPress(.downArrow) { () -> KeyPress.Result in moveInMenu(1) }
                .onKeyPress(.tab) { () -> KeyPress.Result in
                    guard menu.isOpen else { return .ignored }
                    chooseSelected()
                    return .handled
                }
                .onKeyPress(.escape) { () -> KeyPress.Result in
                    guard menu.isOpen else { return .ignored }
                    menu.close()
                    return .handled
                }
                .onChange(of: reply) { _, text in updateMenu(text) }
                .disabled(sending || drafting)
            NookIconButton(systemName: asksNook ? "sparkles" : (whatsAppChat == nil ? "doc.on.doc" : "arrow.up"),
                           label: submitLabel, filled: true, size: 28) { submit() }
                .disabled(sending || drafting || (!asksNook && reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .help(submitLabel)
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.sheet)
    }

    /// The menu for what is typed: "@" offers "@nook" and the ready-made requests, in the user's language.
    private func updateMenu(_ text: String) {
        let presets = ChatDraft.presetKeys.map { tr($0) }
        menu.show(ChatDraft.choices(for: text, presets: presets).map { choice in
            ComposerSuggestion(id: "nook:" + choice.insertion, title: choice.title,
                               detail: tr(choice.isNook ? "chats.nook.detail" : "chats.nook.presetDetail"), symbol: "sparkles",
                               payload: .command(ComposerCommand(name: choice.insertion, insertion: choice.insertion, action: .insert)))
        })
    }

    /// A line of the menu fills the field; Return then lets Nook write.
    private func choose(_ row: ComposerSuggestion) {
        guard case .command(let command) = row.payload else { return }
        reply = command.insertion
        menu.close()
        replyFocused = true
    }

    private func chooseSelected() {
        guard menu.suggestions.indices.contains(menu.selection) else { return }
        choose(menu.suggestions[menu.selection])
    }

    private func moveInMenu(_ delta: Int) -> KeyPress.Result {
        guard menu.isOpen else { return .ignored }
        menu.move(delta)
        return .handled
    }

    private var submitLabel: String {
        if asksNook { return tr("chats.draft.button") }
        return whatsAppChat == nil ? tr("chats.reply.copy", appName) : tr("chats.send")
    }

    /// Return or the button: Nook writes for "@nook …", a WhatsApp chat gets the text, any other chat's app gets it on
    /// the clipboard and comes to the front.
    private func submit() {
        if let instruction = ChatDraft.instruction(in: reply) {
            draft(instruction)
        } else if let chat = whatsAppChat {
            send(to: chat)
        } else {
            copyForApp()
        }
    }

    /// Nook writes the message from this chat's newest messages and what you asked, and puts it in the field.
    private func draft(_ instruction: String) {
        guard !drafting else { return }
        drafting = true
        notice = tr("chats.draft.writing")
        let transcript = ChatBubble.transcript(Array(bubbles.suffix(30)), contact: entry.name)
        Task { @MainActor in
            defer { drafting = false }
            do {
                reply = try await app.draftChatMessage(app: appName, chat: entry.name, transcript: transcript, instruction: instruction)
                notice = whatsAppChat == nil ? tr("chats.draft.readyCopy", appName) : tr("chats.draft.ready")
                replyFocused = true
            } catch {
                notice = error.localizedDescription
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

    /// Nook cannot write in this app: the text goes on the clipboard and the app opens, to paste it there.
    private func copyForApp() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        reply = ""
        notice = tr("chats.reply.copied", appName)
        app.openChatApp(entry.app)
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
