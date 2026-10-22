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
    /// The phone number behind a private WhatsApp chat, to find its photo in Contacts. Nil for a group, a Beeper chat
    /// and a chat collected from notifications, which are matched by name.
    var handle: String? = nil
    /// The chat's own picture from its app (a group's, a channel's, a person's), which goes before Contacts.
    var avatar: String? = nil
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
/// Nook collects (Telegram, Instagram, Messenger, Signal, Messages…), newest first in groups per day that fold shut.
/// "All" and "Unread" on top, one row of app filters (icons, the rest behind "+N") with what is unread there, and a search. A chat opens on the right as bubbles; a WhatsApp chat can be answered there (one of its messages too, and each can get an emoji), any other opens in its own app. A photo enlarges right there.
/// Collecting is turned on in Settings › Connections › On your Mac › Chats.
struct ChatsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    /// Shows the panel footer under the list of chats, where Agents has it under its sessions, so the refresh and update
    /// button sits in the same place on every tab. A footer page (pull requests, usage) opens on Agents through it.
    var openOnAgents: ((String) -> Void)?
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @ObservedObject private var photos = ContactPhotos.shared
    /// The open chat: the one you opened last, also after the tab was closed or Nook restarted; nil shows none.
    @State private var selection: String? = ChatsTab.lastOpened
    /// One app's chats only (its source id), or all.
    @State private var filter: String?
    /// Only the chats with something unread; the chat you opened stays while you read it.
    @State private var unreadOnly = false
    @State private var query = ""
    /// The groups folded shut (a click on their header); a search shows every group open.
    @State private var collapsed: Set<ChatsGroup> = []
    @AppStorage("nook.chats.listWidth") private var listWidth = PanelLayout.chatsList
    /// Settings › Chats: opening a chat marks it read, in Nook only. Off by default.
    @AppStorage(ChatsTab.readOnOpenKey) private var readOnOpen = false
    @State private var totalWidth: Double = 0

    static let readOnOpenKey = "nook.chats.readOnOpen"

    /// The chat you opened last, kept for the next time the tab opens.
    static var lastOpened: String? {
        get { UserDefaults.standard.string(forKey: "nook.chats.lastOpened") }
        set { UserDefaults.standard.set(newValue, forKey: "nook.chats.lastOpened") }
    }

    /// Unread messages in every chat, for the dot on the tab.
    @MainActor
    static var unread: Int {
        let link = WhatsAppLink.shared
        return ChatCaptureService.shared.inbox.totalUnread + (link.isConnected ? link.inbox.visibleUnread(filters: link.filters) : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if capture.status == .needsAccess { accessBar }
            if case .failed(let why) = capture.status { failedBar(why) }
            if all.isEmpty {
                empty
                // No list yet: the footer keeps the list's width at the bottom.
                if showsFooter { footer.frame(width: min(listWidth, max(totalWidth, PanelLayout.minimumList))) }
            } else {
                // The same split as the Agents tab: a list you can widen, a line, and the open chat beside it.
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        list
                        footer
                    }
                    .padding(.trailing, NookTheme.Spacing.xs)
                    .resizablePanel(width: $listWidth, defaultWidth: PanelLayout.chatsList, minimum: PanelLayout.minimumList,
                                    available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                                    edge: .trailing, divider: true)
                    Group {
                        if let current {
                            ChatsDetail(entry: current, photo: photo(current), capture: capture, whatsApp: whatsApp,
                                        onMarkUnread: { markUnread(current) })
                                .id(current.id)
                        } else {
                            // No chat open (none picked yet, closed with Escape, or not in what the list shows).
                            VStack(spacing: NookTheme.Spacing.sm) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(NookTheme.font(26, .light))
                                    .foregroundStyle(NookTheme.textMuted)
                                    .accessibilityHidden(true)
                                Text(tr("chats.placeholder"))
                                    .font(NookTheme.TextStyle.body)
                                    .foregroundStyle(NookTheme.textSecondary)
                                Text(tr("chats.placeholderDetail"))
                                    .font(NookTheme.TextStyle.caption)
                                    .foregroundStyle(NookTheme.textTertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(.leading, NookTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .onAppear {
            takeFocus()
            photos.refresh()
        }
        // The pictures of the WhatsApp chats in the list, newest first, as their app shows them.
        // Again once the list of chats on the phone (and its channels) came in.
        .task(id: "\(whatsApp.isConnected) \(whatsApp.knownChats.count)") {
            await whatsApp.loadAvatars(all.filter { $0.app == "whatsapp" }.prefix(60).compactMap { entry in
                if case .whatsApp(let jid) = entry.origin { return jid }
                return nil
            })
        }
        .onChange(of: viewModel.chatsFocus) { _, _ in takeFocus() }
        // Escape closes the open chat; the list stays.
        .onExitCommand {
            guard selection != nil else { return }
            withAnimation(NookTheme.reveal) { selection = nil }
        }
        .onChange(of: selection) { _, id in
            ChatsTab.lastOpened = id
        }
        // With "Mark as read when opened" on, a chat you open is read, and so is what comes in while it is open: its
        // badge goes. In Nook only: WhatsApp keeps it unread and the sender sees no blue ticks.
        .onChange(of: current.map { "\($0.id) \($0.unread)" }, initial: true) { _, _ in
            guard readOnOpen, let entry = current, entry.unread > 0 else { return }
            switch entry.origin {
            case .captured(let thread): capture.markRead(thread)
            case .whatsApp(let jid): whatsApp.markReadInNook(jid)
            }
        }
    }

    private var showsFooter: Bool { openOnAgents != nil && !app.demoMode }

    @ViewBuilder
    private var footer: some View {
        if let openOnAgents, showsFooter {
            PanelFooter(selected: "", open: openOnAgents, openSettings: { app.openSettings() }, history: app.history)
        }
    }

    /// "Mark as read", by hand: its badge goes.
    private func markRead(_ entry: ChatsEntry) {
        switch entry.origin {
        case .captured(let thread): capture.markRead(thread)
        case .whatsApp(let jid): whatsApp.markRead(jid)
        }
    }

    /// "Mark as unread", by hand: the badge comes back, and an open chat closes so that opening it again reads it.
    private func markUnread(_ entry: ChatsEntry) {
        if selection == entry.id { withAnimation(NookTheme.reveal) { selection = nil } }
        switch entry.origin {
        case .captured(let thread): capture.markUnread(thread)
        case .whatsApp(let jid): whatsApp.markUnread(jid)
        }
    }

    /// Shows what "@chats …" or "@open chat …" asked for.
    private func takeFocus() {
        guard let focus = viewModel.chatsFocus else { return }
        viewModel.chatsFocus = nil
        filter = focus.app
        unreadOnly = false
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
                    let text = AppModel.whatsAppFileLabel(message.media) ?? ChatFormat.plain(AppModel.whatsAppText(message))
                    let who = message.fromMe ? tr("chat.you") : (conversation.isGroup ? message.senderName : "")
                    return who.isEmpty ? text : "\(who): \(text)"
                } ?? ""
                let newest = conversation.messages.last
                let ticks = newest.flatMap { $0.fromMe ? $0.receipt.map(AppModel.bubbleTicks) : nil }
                entries.append(ChatsEntry(id: "wa|" + conversation.id, origin: .whatsApp(conversation.id), app: "whatsapp",
                                          name: conversation.name, preview: preview, last: conversation.lastActivity,
                                          unread: conversation.unread, ticks: ticks, handle: Self.handle(conversation.id),
                                          avatar: whatsApp.avatars[conversation.id]))
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
                                          preview: "", last: chat.last, unread: 0, handle: Self.handle(chat.jid),
                                          avatar: whatsApp.avatars[chat.jid]))
            }
        }
        for thread in capture.inbox.sorted where capture.sources.isOn(thread.app) {
            let preview = thread.messages.last.map { message in
                let who = message.isMine ? tr("chat.you") : message.sender
                return who.isEmpty ? message.summary : "\(who): \(message.summary)"
            } ?? ""
            entries.append(ChatsEntry(id: thread.id, origin: .captured(thread.id), app: thread.app, name: thread.name,
                                      preview: preview, last: thread.last, unread: thread.unread, avatar: thread.avatar))
        }
        return entries.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
    }

    /// A private WhatsApp chat's phone number; nil for groups, channels and Beeper chats, which have none.
    private static func handle(_ jid: String) -> String? {
        WAJID.kind(jid) == .person && !WAJID.isBeeper(jid) ? jid : nil
    }

    private func photo(_ entry: ChatsEntry) -> NSImage? {
        if let avatar = entry.avatar, FileManager.default.fileExists(atPath: avatar),
           let image = ChatMediaImages.image(URL(fileURLWithPath: avatar), side: 96) {
            return image
        }
        return photos.photo(handle: entry.handle, name: entry.name)
    }

    /// The chats that match the filter and the search, in the list's order: group by group, newest first in each.
    /// A chat keeps its place when it is read, so nothing jumps while you read it.
    private var shown: [ChatsEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let now = Date()
        return all.filter { entry in
            (filter == nil || entry.app == filter)
                && (!unreadOnly || entry.unread > 0 || entry.id == selection)
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

    /// The chat on the right: the one you opened, as long as the list shows it; none until you open one.
    private var current: ChatsEntry? {
        guard let selection else { return nil }
        return shown.first { $0.id == selection }
    }

    /// Unread messages per app, as the list shows them.
    private var unreadByApp: [String: Int] {
        Dictionary(grouping: all, by: \.app).mapValues { $0.reduce(0) { $0 + $1.unread } }
    }

    /// Unread messages in the listed chats: the number on top always adds up to the counts in the list.
    private var unreadTotal: Int { all.reduce(0) { $0 + $1.unread } }

    /// The apps that have chats here: the ones with unread messages first, then the busiest, and the one filtered on
    /// even when it has none yet. After them every source that is on and on this Mac (its app is installed, or you added
    /// it yourself), also before it brought in a message: a source you switched on shows up here, not only once it has chats.
    private var apps: [String] {
        let counts = Dictionary(grouping: all, by: \.app).mapValues(\.count)
        let unread = unreadByApp
        var result = counts.keys.sorted { a, b in
            let (ua, ub) = (unread[a] ?? 0, unread[b] ?? 0)
            if (ua > 0) != (ub > 0) { return ua > 0 }
            return counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b
        }
        if capture.enabled {
            for source in capture.sources.active where !result.contains(source.id) && Self.isPresent(source) {
                result.append(source.id)
            }
        }
        if let filter, !result.contains(filter) { result.append(filter) }
        return result
    }

    /// Whether a source belongs on this Mac: one you added, or a known app that is installed. The known web-only apps
    /// (LinkedIn, X…) wait until they bring in a chat, or the row would list every app Nook knows.
    @MainActor
    private static func isPresent(_ source: MessagingApp) -> Bool {
        if !MessagingApps.builtIn.contains(where: { $0.id == source.id }) { return true }
        return source.bundleIDs.contains { bundleID in
            if let known = installed[bundleID] { return known }
            let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            installed[bundleID] = found
            return found
        }
    }

    /// Which apps are installed, looked up once per launch.
    @MainActor private static var installed: [String: Bool] = [:]

    /// One calm row of sources however many there are: "All", the apps with chats as their icons (the one filtered on
    /// with its name too) as many as fit, and the others behind "+N", unread ones first.
    private var sourceFilters: some View {
        let ranked = apps
        let unread = unreadByApp
        let withChats = Set(all.map(\.app))
        return ViewThatFits(in: .horizontal) {
            sourceRow(ranked, shown: 6, unread: unread, withChats: withChats)
            sourceRow(ranked, shown: 5, unread: unread, withChats: withChats)
            sourceRow(ranked, shown: 4, unread: unread, withChats: withChats)
            sourceRow(ranked, shown: 3, unread: unread, withChats: withChats)
            sourceRow(ranked, shown: 2, unread: unread, withChats: withChats)
            sourceRow(ranked, shown: 1, unread: unread, withChats: withChats)
        }
    }

    private func sourceRow(_ ranked: [String], shown limit: Int, unread: [String: Int], withChats: Set<String>) -> some View {
        let split = ChatsSourceSplit.make(ranked, limit: limit, selected: filter, withChats: withChats)
        return HStack(spacing: NookTheme.Spacing.xs) {
            ChatsFilterChip(title: tr("chats.filter.allSources"), app: nil, selected: filter == nil) { filter = nil }
            ForEach(split.row, id: \.self) { id in
                ChatsFilterChip(title: MessagingApps.app(id: id)?.name ?? id, app: id, unread: unread[id] ?? 0,
                                selected: filter == id, compact: filter != id) {
                    filter = filter == id ? nil : id
                }
            }
            if !split.rest.isEmpty {
                ChatsMoreSources(apps: split.rest, unread: unread) { filter = $0 }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The list's title, as the Agents tab has it: how many messages wait for you, and the list's two actions.
    private var listHeader: some View {
        PanelListHeader(tr("tab.chats"), count: unreadTotal) {
            // WhatsApp's unread marks belong to the phone: a chat there is read by what you do with it.
            if capture.inbox.totalUnread > 0 {
                ToolbarIconButton("checkmark.circle", tr("chats.markAllRead")) { capture.markAllRead() }
            }
            ToolbarIconButton("plus", tr("chats.addSource")) { app.openSettings(section: .chats) }
        }
        .accessibilityValue(unreadTotal > 0 ? "\(tr("chats.group.unread")): \(unreadTotal)" : "")
    }

    private var searchField: some View {
        NookSearchField(prompt: tr("chats.search"), text: $query)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            listHeader
            searchField

            NookTabBar(items: [.init(value: false, title: tr("chats.filter.all")),
                               .init(value: true, title: tr("chats.group.unread"), count: unreadTotal)],
                       selected: unreadOnly) { unreadOnly = $0 }

            if apps.count > 1 { sourceFilters }

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
                                ChatsRow(entry: entry, photo: photo(entry), selected: entry.id == selected) { selection = entry.id }
                                    .contextMenu {
                                        if entry.unread > 0 {
                                            Button(tr("chats.markRead")) { markRead(entry) }
                                        } else {
                                            Button(tr("chats.markUnread")) { markUnread(entry) }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            if shown.isEmpty {
                if unreadOnly, !searching {
                    // Everything read: one click back to every chat.
                    VStack(spacing: NookTheme.Spacing.sm) {
                        ListEmptyNote(tr("chats.unread.none"))
                        SmallGhostButton(title: tr("chats.unread.showAll")) { unreadOnly = false }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, NookTheme.Spacing.xl)
                } else if !searching, let filter {
                    // A source that is on but brought in nothing yet: why, and what to do about it.
                    let name = MessagingApps.app(id: filter)?.name ?? filter
                    VStack(spacing: NookTheme.Spacing.sm) {
                        if let problem = capture.bridgeProblems[filter] {
                            Text(problem)
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.coralSoft)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let bridge = capture.bridge(for: filter),
                                  ![capture.messagesBridge.app, capture.whatsAppDesktopBridge.app].contains(bridge.app), !bridge.isReady {
                            // Slack, Telegram, Teams and Beeper keep their history elsewhere: connected once, Nook reads
                            // it from there.
                            ListEmptyNote(tr("chats.\(bridge.app).connectHint"))
                            SmallGhostButton(title: tr("chats.\(bridge.app).connect")) { app.openSettings(section: .chats) }
                        } else {
                            ListEmptyNote(tr("chats.source.empty", name))
                        }
                        SmallGhostButton(title: tr("chats.openApp", name)) { app.openChatApp(filter) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, NookTheme.Spacing.xl)
                } else {
                    ListEmptyNote(tr("chats.noMatch"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, NookTheme.Spacing.xl)
                }
            }
            if capture.enabled, capture.status == .running, capture.inbox.threads.isEmpty {
                // Collecting is on but no other app showed a message yet: say so, or the list looks like it ignores them.
                Label(tr("chats.status.waiting"), systemImage: "tray")
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NookTheme.Spacing.md)
            }
            if !capture.enabled {
                // Only WhatsApp so far: the other chat apps are one switch away.
                SmallGhostButton(title: tr("chats.addMore")) { app.openSettings(section: .chats) }
            }
            if photos.canAsk {
                // Photos come from Contacts on this Mac; macOS asks only after this click.
                SmallGhostButton(title: tr("chats.photos.allow")) { photos.requestAccess() }
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

    /// The notifications could not be read: why, and a way to try again.
    private func failedBar(_ why: String) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.coral)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("chats.status.failed"))
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                Text(why)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.coralSoft)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            NookNoticeActions(primary: NookNoticeAction(tr("chats.status.retry")) { capture.start() })
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardBackground(NookTheme.field, stroke: NookTheme.coral.opacity(0.4), radius: NookTheme.Radius.card)
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

/// A group of the list: by when a chat last moved, as every chat app has it. What is unread stands out in its row and
/// under "Unread", so reading a chat never moves it.
enum ChatsGroup: Int, Comparable, CaseIterable {
    case today, yesterday, week, month, earlier

    static func < (lhs: ChatsGroup, rhs: ChatsGroup) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .today: return tr("chats.group.today")
        case .yesterday: return tr("chats.group.yesterday")
        case .week: return tr("chats.group.week")
        case .month: return tr("chats.group.month")
        case .earlier: return tr("chats.group.earlier")
        }
    }

    /// Where a chat goes: by its newest message.
    static func of(_ entry: ChatsEntry, now: Date, calendar: Calendar = .current) -> ChatsGroup {
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

/// An app in the filter row: its icon, its name and how many messages there are unread; a second click shows all again.
private struct ChatsFilterChip: View {
    let title: String
    let app: String?
    var unread = 0
    let selected: Bool
    /// Only the app's icon (its name on hover), so many apps fit on one line.
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.xs) {
                if let app {
                    SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: compact ? 15 : 13,
                             source: app)
                }
                if !compact || app == nil {
                    Text(title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                }
                if unread > 0 {
                    Text("\(unread)")
                        .font(NookTheme.font(10, .bold))
                        .foregroundStyle(NookTheme.ink)
                        .padding(.horizontal, NookTheme.Spacing.xs)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(NookTheme.amber))
                }
            }
            .padding(.horizontal, compact ? NookTheme.Spacing.sm : NookTheme.Spacing.md)
            .frame(height: 24)
            .background(Capsule().fill(selected ? NookTheme.smoke : (hovering ? NookTheme.rowHover : Color.clear)))
            .overlay(Capsule().stroke(selected ? NookTheme.line2 : NookTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .fixedSize()
        .accessibilityLabel(unread > 0 ? "\(title), \(tr("chats.group.unread")): \(unread)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Which sources the filter row shows and which wait behind "+N": the first `limit` that have chats (in the order
/// given, unread ones first), with the one filtered on always in the row; sources without chats always wait.
enum ChatsSourceSplit {
    static func make(_ ranked: [String], limit: Int, selected: String?, withChats: Set<String>) -> (row: [String], rest: [String]) {
        var row = Array(ranked.filter { withChats.contains($0) }.prefix(max(limit, 0)))
        if let selected, ranked.contains(selected), !row.contains(selected) {
            if row.count >= max(limit, 1) { row.removeLast() }
            row.append(selected)
        }
        return (row, ranked.filter { !row.contains($0) })
    }
}

/// "+N" at the end of the filter row: the other sources in a menu, with what is unread in each, and a dot when
/// something waits there.
private struct ChatsMoreSources: View {
    let apps: [String]
    let unread: [String: Int]
    let choose: (String) -> Void
    @State private var hovering = false

    private var waiting: Int { apps.reduce(0) { $0 + (unread[$1] ?? 0) } }

    var body: some View {
        Menu {
            ForEach(apps, id: \.self) { id in
                let name = MessagingApps.app(id: id)?.name ?? id
                let count = unread[id] ?? 0
                Button(count > 0 ? "\(name) (\(count))" : name) { choose(id) }
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text("+\(apps.count)")
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                if waiting > 0 {
                    Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(height: 24)
            .background(Capsule().fill(hovering ? NookTheme.rowHover : Color.clear))
            .overlay(Capsule().stroke(NookTheme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(tr("chats.filter.more"))
        .accessibilityLabel(waiting > 0 ? "\(tr("chats.filter.more")), \(tr("chats.group.unread")): \(waiting)" : tr("chats.filter.more"))
    }
}

/// A chat in the list: its app's icon, its name, when and the newest message, and how many you have not read.
private struct ChatsRow: View {
    let entry: ChatsEntry
    let photo: NSImage?
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
                ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 34)
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

/// Who a chat is with: their photo from Contacts, else their initials on a tint of their own (the same color their name
/// has in a group's bubbles), with the app the chat is in as a small badge on the corner.
private struct ChatsAvatar: View {
    let name: String
    let app: String
    let photo: NSImage?
    let size: CGFloat

    private static let colors: [Color] = [NookTheme.mint, NookTheme.blue, NookTheme.violet, NookTheme.music]

    private var tint: Color { Self.colors[ChatTimeline.colorIndex(for: name, count: Self.colors.count)] }

    var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: size * 0.42, source: app)
                    .padding(NookTheme.Spacing.xxs / 2)
                    .background(Circle().fill(NookTheme.canvas))
                    .offset(x: NookTheme.Spacing.xs, y: NookTheme.Spacing.xxs)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let photo {
            Image(nsImage: photo)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .clipShape(Circle())
                .overlay(Circle().stroke(NookTheme.line2, lineWidth: 1))
        } else {
            Circle()
                .fill(tint.opacity(0.16))
                .overlay(Circle().stroke(tint.opacity(0.28), lineWidth: 1))
                .overlay(
                    Text(WAJID.initials(name))
                        .font(NookTheme.rounded(size * 0.36, .semibold))
                        .foregroundStyle(tint)
                )
        }
    }
}

/// The chat on the right: who and which app on top, the messages as bubbles, and how to answer below.
private struct ChatsDetail: View {
    let entry: ChatsEntry
    let photo: NSImage?
    @ObservedObject var capture: ChatCaptureService
    @ObservedObject var whatsApp: WhatsAppLink
    /// "Mark as unread" in the header: the tab closes the chat and shows its badge again.
    var onMarkUnread: () -> Void = {}
    @EnvironmentObject private var app: AppModel
    @State private var reply = ""
    @State private var notice: String?
    @State private var sending = false
    @FocusState private var replyFocused: Bool
    /// A photo shown big over the chat, until it is clicked or Escape is pressed.
    @State private var zoomed: ChatBubble?
    /// The message the field answers, quoted above it until it is sent or let go.
    @State private var replyingTo: ChatBubble?

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
            return (capture.inbox.threads[id]?.messages ?? []).map { ChatBubble($0, time: Self.time.string(from: $0.date)) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, NookTheme.Spacing.md)
            NookDivider()
            ChatTranscript(bubbles: bubbles, contact: entry.name, fills: true,
                           onOpen: { open($0) }, onZoom: { zoom($0) },
                           onReply: whatsAppChat == nil ? nil : quote, onReact: whatsAppChat == nil ? nil : react,
                           onVote: canVote ? vote : nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
                .padding(.top, NookTheme.Spacing.md)
        }
        .overlay {
            if let zoomed, case .photo(let url) = zoomed.media, let image = zoomed.image {
                ChatPhotoZoom(url: url, preview: image, name: zoomed.attachment ?? "",
                              onClose: { withAnimation(NookTheme.reveal) { self.zoomed = nil } },
                              onOpen: { self.zoomed = nil; open(zoomed) })
                    .transition(.opacity)
            }
        }
        .task(id: entry.id) { await loadWhatsApp() }
    }

    /// A photo enlarges over the chat, inside Nook; a photo Nook does not have yet opens as any file does.
    private func zoom(_ bubble: ChatBubble) {
        guard case .photo = bubble.media, bubble.image != nil else { return open(bubble) }
        withAnimation(NookTheme.reveal) { zoomed = bubble }
    }

    /// Whether a poll in this chat can be voted on from here: WhatsApp through a gateway that can, Telegram once linked.
    private var canVote: Bool {
        if whatsAppChat != nil { return whatsApp.canVote }
        return entry.app == capture.telegramBridge.app && capture.bridged.contains(entry.app)
    }

    /// Your vote on a poll, after your own click; when it cannot go, the chat says so and the poll shows the old count.
    private func vote(_ bubble: ChatBubble, _ choice: [String]) {
        guard let chat = whatsAppChat else {
            capture.telegramBridge.vote(choice, message: bubble.id)
            return
        }
        Task { @MainActor in
            do {
                try await whatsApp.vote(choice, poll: bubble.id, chat: chat)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// The field answers this message: it shows above the field until the answer goes.
    private func quote(_ bubble: ChatBubble) {
        withAnimation(NookTheme.reveal) { replyingTo = bubble }
        replyFocused = true
    }

    /// Your emoji on a message, after your own click (the same one again takes it back); the chat shows it at once.
    private func react(_ bubble: ChatBubble, _ emoji: String) {
        guard let chat = whatsAppChat else { return }
        Task { @MainActor in
            do {
                try await app.reactWhatsApp(emoji, to: bubble.id, chat: chat)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 32)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(entry.name)
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                // A chat a bridge reads is the app's own; any other is what its notifications showed.
                Text(whatsAppChat == nil && !capture.bridged.contains(entry.app) ? tr("chats.fromNotifications", appName) : appName)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if let chat = whatsAppChat {
                ToolbarIconButton("sparkles", tr("whatsapp.card.nook")) { app.askNookAboutWhatsApp(chat, name: entry.name) }
            } else if case .captured(let id) = entry.origin {
                ToolbarIconButton("trash", tr("chats.remove")) { capture.remove(id) }
            }
            // Read or unread by hand, for every chat.
            if entry.unread > 0 {
                ToolbarIconButton("checkmark.circle", tr("chats.markRead")) {
                    switch entry.origin {
                    case .captured(let id): capture.markRead(id)
                    case .whatsApp(let jid): whatsApp.markRead(jid)
                    }
                }
            } else {
                ToolbarIconButton("circle.badge", tr("chats.markUnread"), onMarkUnread)
            }
            ToolbarIconButton("arrow.up.forward.app", tr("chats.openApp", appName)) { app.openChatApp(entry.app) }
        }
    }

    /// One field for every chat: what you type goes to a WhatsApp chat, or is copied for the app of any other chat;
    /// "@nook …" lets Nook write the message first, into this field, for you to read before it goes anywhere.
    private var footer: some View {
        ChatReplyField(text: $reply, notice: $notice, focus: $replyFocused,
                       placeholder: whatsAppChat == nil ? tr("chats.reply.copyPrompt", entry.name) : tr("chats.reply.prompt", entry.name),
                       sendSymbol: whatsAppChat == nil ? "doc.on.doc" : "arrow.up",
                       sendLabel: whatsAppChat == nil ? tr("chats.reply.copy", appName) : tr("chats.send"),
                       readyNotice: whatsAppChat == nil ? tr("chats.draft.readyCopy", appName) : tr("chats.draft.ready"),
                       busy: sending,
                       quote: replyingTo?.quote(contact: entry.name),
                       cancelQuote: { withAnimation(NookTheme.reveal) { replyingTo = nil } },
                       draft: { instruction in
                           let transcript = ChatBubble.transcript(Array(bubbles.suffix(30)), contact: entry.name)
                           return try await app.draftChatMessage(app: appName, chat: entry.name, transcript: transcript,
                                                                 instruction: instruction)
                       },
                       send: {
                           if let chat = whatsAppChat { send(to: chat) } else { copyForApp() }
                       })
    }

    /// Your answer goes to the chat as typed (to the quoted message, when one is), after your own Return or click; when
    /// it fails the text and the quote stay.
    private func send(to chat: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        notice = tr("whatsapp.card.sending")
        let quoted = replyingTo?.id
        Task { @MainActor in
            defer { sending = false }
            do {
                try await app.sendWhatsAppFromChats(text, chat: chat, replyTo: quoted)
                reply = ""
                notice = nil
                if replyingTo?.id == quoted { replyingTo = nil }
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

    /// A file opens in Quick Look: from this Mac when Nook has it, from the gateway for WhatsApp, else in its app.
    private func open(_ bubble: ChatBubble) {
        // A file Nook already has opens from this Mac, whichever app it came from.
        if let file = bubble.file {
            if !FilePreviewWindow.shared.show(file, title: bubble.attachment ?? file.lastPathComponent), !NSWorkspace.shared.open(file) {
                notice = tr("whatsapp.file.noApp")
            }
            return
        }
        guard let chat = whatsAppChat else {
            // Not fetched (yet): the chat's own app has it.
            if bubble.attachment != nil { app.openChatApp(entry.app) }
            return
        }
        guard bubble.attachment != nil else { return }
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
