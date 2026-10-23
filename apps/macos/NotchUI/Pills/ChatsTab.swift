import SwiftUI
import UniformTypeIdentifiers
import Combine

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
    /// The newest message, with who wrote it in a group ("Jan: dinner?"). While you search, the newest one that matched.
    var preview: String
    let last: Date
    let unread: Int
    /// The newest message is yours: how far it got (sent, delivered, read), as far as its app says. Nil for theirs, and
    /// for every chat collected from notifications, which only ever show what came in.
    var ticks: BubbleTicks? = nil
    /// A group's other people by name, when its app lists them: the chat's header says how many and lists them.
    var members: [String]? = nil
    /// The phone number behind a private WhatsApp chat, to find its photo in Contacts. Nil for a group, a Beeper chat
    /// and a chat collected from notifications, which are matched by name.
    var handle: String? = nil
    /// The chat's own picture from its app (a group's, a channel's, a person's), which goes before Contacts.
    var avatar: String? = nil
    /// Read in Nook but still unread in the app itself (WhatsApp): "Mark as read" can still tell the app.
    var waitsInApp = false

    /// Whether "Mark as read" applies: unread in Nook, or still unread in the app.
    var readable: Bool { unread > 0 || waitsInApp }
}

/// What the Chats tab opens on when another place sends you there: one app's chats, one chat, or a search.
struct ChatsFocus: Equatable {
    /// The `ChatsEntry` id to select.
    var chat: String?
    /// The app's source id to filter on.
    var app: String?
    var query = ""
}

extension ChatsEntry {
    /// Every chat, newest first. Of WhatsApp every chat you did not hide, quiet groups included: they are all here.
    /// The Chats tab and the iPhone companion read the same list.
    @MainActor
    static func all(whatsApp: WhatsAppLink, capture: ChatCaptureService) -> [ChatsEntry] {
        var entries: [ChatsEntry] = []
        if whatsApp.isConnected {
            for conversation in whatsApp.inbox.sorted where !whatsApp.filters.ignored.contains(conversation.id) {
                let preview = conversation.messages.last.map { line($0, group: conversation.isGroup) } ?? ""
                let newest = conversation.messages.last
                let ticks = newest.flatMap { $0.fromMe ? $0.receipt.map(AppModel.bubbleTicks) : nil }
                entries.append(ChatsEntry(id: "wa|" + conversation.id, origin: .whatsApp(conversation.id), app: "whatsapp",
                                          name: conversation.name, preview: preview, last: conversation.lastActivity,
                                          unread: whatsApp.unread(conversation.id), ticks: ticks,
                                          members: conversation.members == nil ? nil : conversation.memberNames,
                                          handle: handle(conversation.id),
                                          avatar: whatsApp.avatars[conversation.id], waitsInApp: whatsApp.waitsInWhatsApp(conversation.id)))
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
                                          preview: "", last: chat.last, unread: whatsApp.unread(chat.jid), handle: handle(chat.jid),
                                          avatar: whatsApp.avatars[chat.jid], waitsInApp: whatsApp.waitsInWhatsApp(chat.jid)))
            }
        }
        for thread in capture.inbox.sorted where capture.sources.isOn(thread.app) {
            let preview = thread.messages.last.map(line) ?? ""
            let newest = thread.messages.last
            let ticks = newest.flatMap { $0.isMine ? $0.receipt.map(BubbleTicks.init) : nil }
            entries.append(ChatsEntry(id: thread.id, origin: .captured(thread.id), app: thread.app, name: thread.name,
                                      preview: preview, last: thread.last, unread: thread.unread, ticks: ticks,
                                      members: thread.members, avatar: thread.avatar))
        }
        return entries.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
    }

    /// A WhatsApp message as one line in the list, with who wrote it in a group ("Jan: dinner?").
    @MainActor
    static func line(_ message: WAMessage, group: Bool) -> String {
        let text = AppModel.whatsAppFileLabel(message.media) ?? ChatFormat.plain(AppModel.whatsAppText(message))
        let who = message.fromMe ? tr("chat.you") : (group ? message.senderName : "")
        return who.isEmpty ? text : "\(who): \(text)"
    }

    /// A message of any other app as one line in the list.
    @MainActor
    static func line(_ message: InboxMessage) -> String {
        let who = message.isMine ? tr("chat.you") : message.sender
        return who.isEmpty ? message.summary : "\(who): \(message.summary)"
    }

    /// The chat as the Chats tab's search finds it: by its name or its people as it is, else by the newest of its
    /// messages that holds `needle`, which then shows as its line. Every message Nook has of it counts, not only the
    /// newest, so "dinner" finds the Instagram chat where it came up last week. Nil when nothing in it matches.
    @MainActor
    func found(_ needle: String, whatsApp: WhatsAppLink, capture: ChatCaptureService) -> ChatsEntry? {
        if name.localizedCaseInsensitiveContains(needle) || preview.localizedCaseInsensitiveContains(needle)
            || (members ?? []).contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
            return self
        }
        let match: String?
        switch origin {
        case .whatsApp(let jid):
            guard let conversation = whatsApp.inbox.conversations[jid] else { return nil }
            match = conversation.messages.last { message in
                AppModel.whatsAppText(message).localizedCaseInsensitiveContains(needle)
                    || message.senderName.localizedCaseInsensitiveContains(needle)
            }.map { Self.line($0, group: conversation.isGroup) }
        case .captured(let id):
            guard let thread = capture.inbox.threads[id] else { return nil }
            match = thread.messages.last { message in
                message.summary.localizedCaseInsensitiveContains(needle) || message.sender.localizedCaseInsensitiveContains(needle)
            }.map(Self.line)
        }
        guard let match else { return nil }
        var entry = self
        entry.preview = match
        return entry
    }

    /// A private WhatsApp chat's phone number; nil for groups, channels and Beeper chats, which have none.
    static func handle(_ jid: String) -> String? {
        WAJID.kind(jid) == .person && !WAJID.isBeeper(jid) ? jid : nil
    }
}

/// `ChatsEntry.all`, made once and asked many times: the tab asks for it a dozen times while it draws (the list, the
/// filters, the counts, the open chat), and making it goes through every chat. Forgotten as soon as WhatsApp or the other
/// chats change, and once the redraw is over, so it is never older than what it is made of.
@MainActor
final class ChatsEntryMemo {
    private var entries: [ChatsEntry]?
    private var watching: [AnyCancellable] = []

    func entries(whatsApp: WhatsAppLink, capture: ChatCaptureService) -> [ChatsEntry] {
        if let entries { return entries }
        if watching.isEmpty {
            watching = [
                whatsApp.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.entries = nil } },
                capture.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.entries = nil } },
            ]
        }
        let made = ChatsEntry.all(whatsApp: whatsApp, capture: capture)
        entries = made
        DispatchQueue.main.async { [weak self] in self?.entries = nil }
        return made
    }
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
    /// Settings › Chats: opening a chat marks it read, in Nook only. On by default; WhatsApp keeps it unread either way.
    @AppStorage(ChatsTab.readOnOpenKey) private var readOnOpen = true
    @State private var totalWidth: Double = 0
    @State private var entriesMemo = ChatsEntryMemo()

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
                                        onMarkUnread: { markUnread(current) }, onClose: closeChat)
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
                                    .font(NookTheme.TextStyle.detail)
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

    /// Escape (see `ChatsDetail`): the open chat closes; the list stays.
    private func closeChat() {
        guard selection != nil else { return }
        withAnimation(NookTheme.reveal) { selection = nil }
    }

    /// "Mark as read", by hand: its badge goes, and a WhatsApp chat is read in WhatsApp too, so the sender sees it.
    private func markRead(_ entry: ChatsEntry) {
        switch entry.origin {
        case .captured(let thread):
            capture.markRead(thread)
            if let linked = app.linkedChat(app.chatRoute(for: entry)) { app.markLinkedChat(linked.id, read: true) }
        case .whatsApp(let jid): whatsApp.markReadInWhatsApp(jid)
        }
    }

    /// "Mark as unread", by hand: the badge comes back, and an open chat closes so that opening it again reads it.
    private func markUnread(_ entry: ChatsEntry) {
        if selection == entry.id { withAnimation(NookTheme.reveal) { selection = nil } }
        switch entry.origin {
        case .captured(let thread):
            capture.markUnread(thread)
            if let linked = app.linkedChat(app.chatRoute(for: entry)) { app.markLinkedChat(linked.id, read: false) }
        case .whatsApp(let jid): whatsApp.markUnread(jid)
        }
    }

    /// Shows what "@chat …" asked for.
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

    /// Every chat, newest first, as `ChatsEntry.all` lists them: made once per redraw (see `ChatsEntryMemo`).
    private var all: [ChatsEntry] { entriesMemo.entries(whatsApp: whatsApp, capture: capture) }

    private func photo(_ entry: ChatsEntry) -> NSImage? {
        if let avatar = entry.avatar, FileManager.default.fileExists(atPath: avatar),
           let image = ChatMediaImages.image(URL(fileURLWithPath: avatar), side: 96) {
            return image
        }
        return photos.photo(handle: entry.handle, name: entry.name)
    }

    /// The chats that match the filter and the search (their names, their people and every message Nook has of them), in
    /// the list's order: group by group, newest first in each.
    /// A chat keeps its place when it is read, so nothing jumps while you read it.
    private var shown: [ChatsEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let now = Date()
        let found = needle.isEmpty ? all : all.compactMap { $0.found(needle, whatsApp: whatsApp, capture: capture) }
        return found.filter { entry in
            (filter == nil || entry.app == filter) && (!unreadOnly || entry.unread > 0 || entry.id == selection)
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
    /// even when it has none yet. After them every source that is on and on this Mac (its app is installed, you added it
    /// yourself, or Nook reads it with your login, as Instagram), also before it brought in a message: a source you switched
    /// on shows up here, not only once it has chats.
    private var apps: [String] {
        let counts = Dictionary(grouping: all, by: \.app).mapValues(\.count)
        let unread = unreadByApp
        var result = counts.keys.sorted { a, b in
            let (ua, ub) = (unread[a] ?? 0, unread[b] ?? 0)
            if (ua > 0) != (ub > 0) { return ua > 0 }
            return counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b
        }
        if capture.enabled {
            for source in capture.sources.active
            where !result.contains(source.id) && (Self.isPresent(source) || capture.bridge(for: source.id)?.isReady == true) {
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

    /// The list's title, as the Agents tab has it, with the list's two actions. What is unread is counted once, on the
    /// Unread filter right under it, not again here.
    private var listHeader: some View {
        PanelListHeader(tr("tab.chats")) {
            // WhatsApp's unread marks belong to the phone: a chat there is read by what you do with it.
            if capture.inbox.totalUnread > 0 {
                ToolbarIconButton("checkmark.circle", tr("chats.markAllRead")) { capture.markAllRead() }
            }
            ToolbarIconButton("plus", tr("chats.addSource")) { app.openSettings(section: .chats) }
        }
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
                                if entry.id != section.entries.first?.id { NookRowSeparator() }
                                ChatsRow(entry: entry, photo: photo(entry), selected: entry.id == selected,
                                         onToggleRead: { entry.readable ? markRead(entry) : markUnread(entry) }) { selection = entry.id }
                                    .contextMenu {
                                        if entry.readable {
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
            listHints
        }
    }

    /// The quiet hints at the foot of the list, together in one place: what Nook waits for, and what one click adds.
    @ViewBuilder
    private var listHints: some View {
        let waiting = capture.enabled && capture.status == .running && capture.inbox.threads.isEmpty
        if waiting || !capture.enabled || photos.canAsk {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                if waiting {
                    // Collecting is on but no other app showed a message yet: say so, or the list looks like it ignores them.
                    Label(tr("chats.status.waiting"), systemImage: "tray")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NookTheme.Spacing.lg)
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
    /// The same notice bar the panel shows under its tabs: why, in a line, with the one action that fixes it.
    private func failedBar(_ why: String) -> some View {
        PanelNoticeBar(title: tr("chats.status.failed"), detail: why, symbol: "exclamationmark.triangle.fill",
                       tone: NookTheme.coral, help: why) {
            NookNoticeActions(primary: NookNoticeAction(tr("chats.status.retry")) { capture.start() })
                .fixedSize()
        }
    }

    /// macOS keeps its notifications behind Full Disk Access.
    private var accessBar: some View {
        PanelNoticeBar(title: tr("chats.capture.needsAccess"), symbol: "lock.fill", tone: NookTheme.amber) {
            NookNoticeActions(primary: NookNoticeAction(tr("chats.capture.grant")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            })
            .fixedSize()
        }
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
                // Written as a group's name everywhere else (no capitals, no tracking); the chevron says it folds.
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(8, .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering || !open ? 1 : 0)
                Spacer(minLength: NookTheme.Spacing.xs)
                if !open {
                    Text("\(count)")
                        .font(NookTheme.TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.top, first ? NookTheme.Spacing.xs : NookTheme.Spacing.lg)
            .padding(.bottom, NookTheme.Spacing.xs)
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
                    // A dot, as on "+N": the count itself is on the Unread filter and in each chat's row.
                    Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, compact ? NookTheme.Spacing.sm : NookTheme.Spacing.md)
            .frame(height: 26)
            .background(Capsule().fill(selected ? NookTheme.smoke : (hovering ? NookTheme.rowHover : Color.clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(unread > 0 ? "\(title), \(tr("chats.group.unread")): \(unread)" : title)
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
            .frame(height: 26)
            .background(Capsule().fill(hovering ? NookTheme.rowHover : Color.clear))
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
    /// Read or unread by hand, from the button that shows while the pointer is on the row.
    var onToggleRead: (() -> Void)? = nil
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
        ZStack(alignment: .topTrailing) {
            // VoiceOver reaches the row itself, so the action is named there; the hover button would only repeat it.
            row.accessibilityAction(named: Text(tr(entry.readable ? "chats.markRead" : "chats.markUnread"))) { onToggleRead?() }
            // As the Nook and agent lists have it: the row's action where its time was, while the pointer is on it.
            if let onToggleRead {
                ToolbarIconButton(entry.readable ? "envelope.open" : "envelope.badge",
                                  tr(entry.readable ? "chats.markRead" : "chats.markUnread"), height: 22, width: 22, onToggleRead)
                    .pointerStyle(.link)
                    .padding(.top, NookTheme.Spacing.sm)
                    .padding(.trailing, NookTheme.Spacing.sm)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .accessibilityHidden(true)
            }
        }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 34)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    // One title line (who, when) and one line under it (the newest message); unread is said once, by
                    // the count at the end of the second line.
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                        Text(entry.name)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.xs)
                        Text(when)
                            .font(NookTheme.TextStyle.caption)
                            .monospacedDigit()
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize()
                            .opacity(hovering && onToggleRead != nil ? 0 : 1)
                    }
                    HStack(spacing: NookTheme.Spacing.sm) {
                        if let ticks = entry.ticks { TicksView(ticks: ticks) }
                        // A chat on the phone that wrote nothing since Nook was linked: its messages load when opened.
                        Text(entry.preview.isEmpty ? tr("chats.row.load") : entry.preview)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(entry.preview.isEmpty ? NookTheme.textTertiary : NookTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.xs)
                        NookCountBadge(count: entry.unread)
                            .fixedSize()
                        // Read in Nook, still unread in the app: a ring where the count was, until "Mark as read".
                        if entry.unread == 0, entry.waitsInApp {
                            Circle()
                                .stroke(NookTheme.amber, lineWidth: 1.5)
                                .frame(width: 8, height: 8)
                                .help(tr("chats.waitsInApp", MessagingApps.app(id: entry.app)?.name ?? entry.app))
                                .accessibilityLabel(tr("chats.waitsInApp", MessagingApps.app(id: entry.app)?.name ?? entry.app))
                        }
                    }
                }
            }
            // The avatar lines up with the list's title and its group names above it.
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(entry.unread > 0
            ? "\(MessagingApps.app(id: entry.app)?.name ?? entry.app), \(entry.name), \(tr("chats.group.unread")): \(entry.unread): \(entry.preview)"
            : "\(MessagingApps.app(id: entry.app)?.name ?? entry.app), \(entry.name): \(entry.preview)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Who a chat is with: their photo from Contacts, else their initials on a tint of their own (the same color their name
/// has in a group's bubbles), with the app the chat is in as a small badge on the corner. Search shows the same face on
/// a chat result.
struct ChatsAvatar: View {
    let name: String
    let app: String
    let photo: NSImage?
    let size: CGFloat

    private var tint: Color { ChatPersonBadge.tint(for: name) }

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
        } else {
            Circle()
                .fill(tint.opacity(0.16))
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
    /// Escape: the tab closes the chat.
    var onClose: () -> Void = {}
    @EnvironmentObject private var app: AppModel
    @State private var reply = ""
    @State private var notice: String?
    /// The answer on its way to the chat, then briefly that it is there.
    @State private var outgoing: ChatSending?
    @FocusState private var replyFocused: Bool
    /// A photo shown big over the chat, until it is clicked or Escape is pressed.
    @State private var zoomed: ChatBubble?
    /// The message the field answers, quoted above it until it is sent or let go.
    @State private var replyingTo: ChatBubble?
    /// Your message whose text the field changes, shown above it until the change goes or is let go.
    @State private var editing: ChatBubble?
    /// Your message waiting for "Delete for everyone" to be confirmed.
    @State private var deleting: ChatBubble?
    /// The chats Nook writes in through the linked chat service, for what can be done in this one.
    @ObservedObject private var linked = ChatCaptureService.shared.beeperBridge
    /// Files waiting to go, the poll, place, contact or sticker panel, and the voice recorder.
    @StateObject private var composer = ChatComposerModel()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The key of a chat's unsent answer in `ComposerDraftStore`.
    private static func draftKey(_ chatID: String) -> String { "chat:" + chatID }

    private var appName: String { MessagingApps.app(id: entry.app)?.name ?? entry.app }

    private var whatsAppChat: String? {
        if case .whatsApp(let jid) = entry.origin { return jid }
        return nil
    }

    /// Where what you send goes: WhatsApp, Telegram or Beeper; nil copies the text for the chat's own app.
    private var route: ChatRoute? { app.chatRoute(for: entry) }

    /// This chat as the linked chat service has it (pinned, muted, what it takes); nil when it is not one of those.
    private var linkedChat: BeeperData.Chat? {
        guard case .beeper(let id) = route else { return nil }
        return linked.chats[id]
    }

    /// The stickers and GIFs in this chat, newest first, for the sticker panel.
    private var shelfItems: [ChatShelfItem] {
        bubbles.reversed().compactMap { bubble in
            switch bubble.media {
            case .sticker(let url): return ChatShelfItem(url: url, gif: false)
            case .gif(let url): return ChatShelfItem(url: url, gif: true)
            default: return nil
            }
        }
    }

    private var bubbles: [ChatBubble] {
        switch entry.origin {
        case .whatsApp(let jid):
            return whatsApp.inbox.conversations[jid].map { AppModel.whatsAppBubbles($0) } ?? []
        case .captured(let id):
            let thread = capture.inbox.threads[id]
            return (thread?.messages ?? []).map { ChatBubble($0, time: Self.time.string(from: $0.date), members: thread?.members ?? []) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, NookTheme.Spacing.md)
            NookDivider()
            ChatTranscript(bubbles: bubbles, contact: entry.name, fills: true,
                           onOpen: { open($0) }, onZoom: { zoom($0) },
                           onReply: route == nil ? nil : quote,
                           onReact: whatsAppChat != nil || linkedChat?.canReact == true ? react : nil,
                           onEdit: linkedChat?.canEdit == true ? edit : nil,
                           onDelete: linkedChat?.canDelete == true ? { deleting = $0 } : nil,
                           onVote: canVote ? vote : nil, onLoadOlder: canLoadOlder ? loadOlder : nil)
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
        .confirmDelete($deleting, question: { _ in tr("chat.delete.question") }, detail: tr("chat.delete.detail", appName),
                       confirmTitle: tr("chat.delete")) { delete($0) }
        .task(id: entry.id) { await loadWhatsApp() }
        // Nothing waiting for one chat goes to the next.
        .onChange(of: entry.id) { _, id in
            composer.reset()
            editing = nil
            reply = ComposerDraftStore.shared.draft(for: Self.draftKey(id)) ?? ""
        }
        // What you were typing to this chat stays when the notch closes, and comes back when you open the chat again.
        .onAppear {
            if reply.isEmpty, let saved = ComposerDraftStore.shared.draft(for: Self.draftKey(entry.id)) { reply = saved }
        }
        // A message's text being changed is not an unsent answer.
        .onChange(of: reply) { _, text in
            guard editing == nil else { return }
            ComposerDraftStore.shared.save(sessionID: Self.draftKey(entry.id), text: text)
        }
        // A file or picture dropped on the chat waits above the field, as one chosen with "+".
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            !app.chatSends(route).isEmpty && composer.accept(providers)
        }
        // Escape, also when nothing in the chat has the keyboard (a row in the list was clicked last).
        .onEscapeKey(perform: escape)
    }

    /// Escape first shrinks an enlarged photo back, closes a poll, place, contact or sticker panel, and lets go of a
    /// message being changed or quoted; only then does it close the chat.
    private func escape() {
        if zoomed != nil {
            withAnimation(NookTheme.reveal) { zoomed = nil }
        } else if composer.panel != nil {
            composer.closePanel()
        } else if editing != nil {
            withAnimation(NookTheme.reveal) { editing = nil }
            reply = ""
        } else if replyingTo != nil {
            withAnimation(NookTheme.reveal) { replyingTo = nil }
        } else {
            onClose()
        }
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
        Task { @MainActor in
            do {
                if let chat = whatsAppChat {
                    try await app.reactWhatsApp(emoji, to: bubble.id, chat: chat)
                } else if let chat = linkedChat {
                    try await app.reactInLinkedChat(emoji, to: bubble, chat: chat.id, name: entry.name)
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// The field takes your message's text to change it; Return sends the change instead of a new message.
    private func edit(_ bubble: ChatBubble) {
        withAnimation(NookTheme.reveal) {
            replyingTo = nil
            editing = bubble
        }
        reply = bubble.text
        replyFocused = true
    }

    /// The changed text goes to your message; when it fails the text stays in the field to try again.
    private func sendEdit(_ bubble: ChatBubble, chat: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, outgoing?.sent ?? true else { return }
        guard text != bubble.text else {
            withAnimation(NookTheme.reveal) { editing = nil }
            reply = ""
            return
        }
        let shown = ChatSending(text: text)
        outgoing = shown
        notice = nil
        reply = ""
        Task { @MainActor in
            do {
                try await app.editInLinkedChat(bubble, text: text, chat: chat, name: entry.name)
                if editing?.id == bubble.id { withAnimation(NookTheme.reveal) { editing = nil } }
                await showSent(shown)
            } catch {
                outgoing = nil
                if reply.isEmpty { reply = text }
                notice = error.localizedDescription
            }
        }
    }

    /// Your message goes for everyone in the chat, once you confirmed it.
    private func delete(_ bubble: ChatBubble) {
        guard let chat = linkedChat else { return }
        Task { @MainActor in
            do {
                try await app.deleteInLinkedChat(bubble, chat: chat.id, name: entry.name)
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Pins, mutes or archives the chat in its app; a failure shows under the field.
    private func change(_ action: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch { notice = error.localizedDescription }
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
                HStack(spacing: NookTheme.Spacing.xs) {
                    // A chat a bridge reads is the app's own; any other is what its notifications showed.
                    Text(whatsAppChat == nil && !capture.bridged.contains(entry.app) ? tr("chats.fromNotifications", appName) : appName)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                    // A group whose app lists its people: how many, and a click lists them.
                    if let members = entry.members, !members.isEmpty {
                        Text("·")
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .accessibilityHidden(true)
                        ChatMembersButton(members: members)
                    }
                }
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            // What you do most stays in sight (ask Nook, open the app); the rest waits in the "…" menu.
            if let chat = whatsAppChat {
                ToolbarIconButton("sparkles", tr("whatsapp.card.nook")) { app.askNookAboutWhatsApp(chat, name: entry.name) }
            }
            ToolbarIconButton("arrow.up.forward.app", tr("chats.openApp", appName)) { app.openChatApp(entry.app) }
            moreMenu
        }
    }

    /// Read or unread by hand, for every chat, and removing a chat collected from notifications.
    private var moreMenu: some View {
        Menu {
            if entry.readable {
                Button(tr("chats.markRead")) {
                    switch entry.origin {
                    case .captured(let id):
                        capture.markRead(id)
                        if let chat = linkedChat { app.markLinkedChat(chat.id, read: true) }
                    case .whatsApp(let jid): whatsApp.markReadInWhatsApp(jid)
                    }
                }
            } else {
                Button(tr("chats.markUnread"), action: onMarkUnread)
            }
            if let chat = linkedChat, case .captured(let thread) = entry.origin {
                Divider()
                Button(tr(chat.isPinned ? "chats.unpinInApp" : "chats.pinInApp", appName)) {
                    change { try await app.setLinkedChatPinned(!chat.isPinned, chat: chat.id, name: entry.name) }
                }
                Button(tr(chat.isMuted ? "chats.unmuteInApp" : "chats.muteInApp", appName)) {
                    change { try await app.setLinkedChatMuted(!chat.isMuted, chat: chat.id, name: entry.name) }
                }
                Button(tr("chats.archiveInApp", appName)) {
                    change {
                        try await app.archiveLinkedChat(chat.id, thread: thread, name: entry.name)
                        onClose()
                    }
                }
            }
            if case .captured(let id) = entry.origin {
                Divider()
                Button(tr("chats.remove"), role: .destructive) { capture.remove(id) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .composerMenu()
        .help(tr("chat.moreActions"))
        .accessibilityLabel(tr("chat.moreActions"))
    }

    /// One field for every chat: what you type goes to a chat Nook can write in (WhatsApp, Telegram, a Beeper network),
    /// or is copied for the app of any other chat; "@nook …" lets Nook write the message first, into this field, for
    /// you to read before it goes anywhere. Where Nook can write, the field takes more than text, as the app's own does:
    /// photos, videos, GIFs, stickers, files, a voice message, a poll, a place, a contact, an emoji.
    @ViewBuilder
    private var footer: some View {
        let route = self.route
        let sends = app.chatSends(route)
        let field = ChatReplyField(
            text: $reply, notice: $notice, focus: $replyFocused,
            placeholder: route == nil ? tr("chats.reply.copyPrompt", entry.name) : tr("chats.reply.prompt", entry.name),
            sendSymbol: route == nil ? "doc.on.doc" : "arrow.up",
            sendLabel: route == nil ? tr("chats.reply.copy", appName) : tr("chats.send"),
            readyNotice: route == nil ? tr("chats.draft.readyCopy", appName) : tr("chats.draft.ready"),
            outgoing: outgoing,
            recipient: entry.name,
            quote: editing.map { BubbleQuote(sender: tr("chat.editing"), text: $0.text, mine: true) }
                ?? replyingTo?.quote(contact: entry.name),
            cancelQuote: {
                withAnimation(NookTheme.reveal) {
                    if editing != nil { reply = "" }
                    editing = nil
                    replyingTo = nil
                }
            },
            onEscape: escape,
            draft: { instruction in
                let transcript = ChatBubble.transcript(Array(bubbles.suffix(30)), contact: entry.name)
                return try await app.draftChatMessage(app: appName, chat: entry.name, transcript: transcript,
                                                      instruction: instruction)
            },
            send: {
                if let editing, let chat = linkedChat {
                    sendEdit(editing, chat: chat.id)
                } else if let route {
                    send(via: route)
                } else {
                    copyForApp()
                }
            })
        if sends.isEmpty {
            field
        } else {
            field.extras(
                pending: composer.hasFiles,
                replacing: composer.recorder.recording
                    ? AnyView(ChatRecordingBar(recorder: composer.recorder) { sendItem(.file($0)) }) : nil,
                paste: { composer.paste() },
                leading: {
                    ChatAttachMenu(model: composer, sends: sends)
                    ChatEmojiButton(text: $reply)
                },
                above: {
                    ChatComposerPanels(model: composer, sends: sends, chatStickers: shelfItems) { sendItem($0) }
                },
                idle: {
                    ChatMicButton(recorder: composer.recorder) { notice = $0.localizedDescription }
                })
        }
    }

    /// What waits goes to the chat (to the quoted message, when one is), after your own Return or click: the files
    /// first, the typed text as the caption of the first one that takes a caption, else as a message after them. It
    /// leaves the field for the sending panel above it, which says when it is there; when it fails the text is back in
    /// the field, the files that did not go still wait, and the quote stays.
    private func send(via route: ChatRoute) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = composer.files
        guard !text.isEmpty || !files.isEmpty, outgoing?.sent ?? true else { return }
        let shown = ChatSending(text: Self.summary(text: text, files: files))
        outgoing = shown
        notice = nil
        reply = ""
        let quoted = replyingTo?.id
        Task { @MainActor in
            // The text still to go: once it went as a caption, a failure later does not put it back to go twice.
            var caption = text
            do {
                var answers = quoted
                for var file in files {
                    let captioned = !caption.isEmpty && [ChatMedia.Kind.photo, .video, .gif, .file].contains(file.kind)
                    if captioned { file.caption = caption }
                    try await app.sendChatItem(.file(file), route: route, chat: entry.name, replyTo: answers)
                    composer.sent(.file(file))
                    answers = nil
                    if captioned { caption = "" }
                }
                if !caption.isEmpty {
                    try await app.sendChatText(caption, route: route, chat: entry.name, replyTo: answers)
                }
                if replyingTo?.id == quoted { replyingTo = nil }
                replyFocused = true
                await showSent(shown)
            } catch {
                outgoing = nil
                if !caption.isEmpty, reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reply = caption }
                notice = tr("whatsapp.card.notSent", error.localizedDescription)
            }
        }
    }

    /// One thing sent at once, after your own click: a poll, a place, a contact, a sticker, a voice message. It shows in
    /// the sending panel as the chat list will name it ("📊 Lunch?").
    private func sendItem(_ item: ChatOutgoing) {
        guard let route = self.route, outgoing?.sent ?? true else { return }
        let shown = ChatSending(text: item.line)
        outgoing = shown
        notice = nil
        let quoted = replyingTo?.id
        Task { @MainActor in
            do {
                try await app.sendChatItem(item, route: route, chat: entry.name, replyTo: quoted)
                composer.sent(item)
                if quoted != nil, replyingTo?.id == quoted { replyingTo = nil }
                await showSent(shown)
            } catch {
                outgoing = nil
                notice = tr("whatsapp.card.notSent", error.localizedDescription)
            }
        }
    }

    /// The sending panel says the message is there for a moment, then lets go (unless a newer one is on its way).
    private func showSent(_ shown: ChatSending) async {
        let sent = ChatSending(text: shown.text, sent: true)
        outgoing = sent
        try? await Task.sleep(for: .seconds(1.4))
        if outgoing == sent { outgoing = nil }
    }

    /// What the sending panel shows for text and files going together: the text, else the files one after another.
    private static func summary(text: String, files: [ChatAttachment]) -> String {
        guard text.isEmpty else { return text }
        return files.map { ChatOutgoing.file($0).line }.joined(separator: ", ")
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

    /// A WhatsApp chat that is full and may have older messages at the gateway.
    private var canLoadOlder: Bool {
        guard let chat = whatsAppChat else { return false }
        return whatsApp.inbox.conversations[chat]?.canLoadOlder ?? false
    }

    private func loadOlder() async -> Bool {
        guard let chat = whatsAppChat else { return false }
        return await whatsApp.loadOlder(chat)
    }

    /// Older messages and the newest photos of a WhatsApp chat, as its card fetches them.
    private func loadWhatsApp() async {
        guard let chat = whatsAppChat else { return }
        _ = await whatsApp.loadHistory(chat)
        // A group's people: its header lists them, and your messages' info says who does not have them yet.
        await whatsApp.loadMembers(chat)
        guard let conversation = whatsApp.inbox.conversations[chat] else { return }
        let wanted = conversation.messages.filter { AppModel.whatsAppPreviews($0.media) }.suffix(AppModel.whatsAppPreviewCount)
            .filter { whatsApp.preview($0.id) == nil }.map(\.id)
        if !wanted.isEmpty { _ = await whatsApp.loadPreviews(wanted, chat: chat) }
    }
}
