import SwiftUI
import UniformTypeIdentifiers
import Combine

/// One chat in the Chats tab, the same for every app: a chat in the shared inbox (`InboxThread`), whichever bridge or
/// notification brought it (WhatsApp through the linked phone, Telegram, Slack, Messages, the chat helper's networks…).
struct ChatsEntry: Identifiable, Equatable {
    /// The `InboxThread` id.
    let id: String
    /// The app's source id ("telegram").
    let app: String
    let name: String
    /// The newest message, with who wrote it in a group ("Jan: dinner?"). While you search, the newest one that matched.
    var preview: String
    let last: Date
    /// Where the chat stands, the same for every app: something new, read in Nook only, or read in the app too.
    let read: ChatReadState
    /// The newest message is your own: nothing in it waits to be read, its ticks say how far it got.
    var lastIsMine = false
    /// Nook knows where the chat stands in its app; when not (a WhatsApp gateway that counts nothing), the row shows no
    /// mark rather than a wrong one.
    var readKnown = true
    /// The newest message is yours: how far it got (sent, delivered, read), as far as its app says. Nil for theirs, and
    /// for every chat collected from notifications, which only ever show what came in.
    var ticks: BubbleTicks? = nil
    /// A group's other people by name, when its app lists them: the chat's header says how many and lists them.
    var members: [String]? = nil
    /// The phone number behind a private chat, to find its photo in Contacts, when its app gives one. Nil for a group
    /// and for a chat matched by name.
    var handle: String? = nil
    /// The chat's own picture from its app (a group's, a channel's, a person's), which goes before Contacts.
    var avatar: String? = nil
    /// The account the chat is in, by its name, while its app has more than one linked; nil otherwise.
    var account: String? = nil
    /// The chat's own id in its app, when its app gives one (`InboxThread.chatID`).
    var chatID: String? = nil

    /// New messages here.
    var unread: Int { read.count }
    /// Read in Nook but still unread in the app itself: "Mark as read in <app>" can still pass it on.
    var waitsInApp: Bool { read == .readInNook }
    /// Whether the row shows where the chat stands: not while the newest message is yours and nothing waits.
    var showsReadMark: Bool { read.isUnread || (readKnown && !lastIsMine) }
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
    /// Every chat that shows (`ChatCaptureService.isShown`), newest first, the same way for every app. The Chats tab and
    /// the iPhone companion read the same list.
    @MainActor
    static func all(capture: ChatCaptureService) -> [ChatsEntry] {
        // A message you deleted for yourself is no chat's newest line either.
        let hidden = ChatHiddenMessages.shared
        // One chat, one row: an app that names the same chat twice (a chat without a topic is named after whoever wrote
        // last) leaves two threads holding the same messages. The one a bridge reads stays (it keeps getting the new
        // messages and the app's own name), else the fuller one. A chat its app knows by an id is never named twice, and
        // two of them may share a message (one group in two linked WhatsApp accounts): they stay two rows.
        var keeper: [String: InboxThread] = [:]
        let threads = capture.inbox.sorted.filter(capture.isShown)
        for thread in threads {
            guard thread.chatID == nil, let id = thread.messages.last?.id else { continue }
            let key = thread.app + "|" + id
            if let kept = keeper[key], !ChatsEntry.isBetter(thread, than: kept) { continue }
            keeper[key] = thread
        }
        var entries: [ChatsEntry] = []
        for thread in threads {
            if thread.chatID == nil, let id = thread.messages.last?.id, keeper[thread.app + "|" + id]?.id != thread.id { continue }
            entries.append(entry(thread, hidden: hidden))
        }
        return entries.sorted { $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id }
    }

    /// One chat as a row.
    @MainActor
    static func entry(_ thread: InboxThread, hidden: ChatHiddenMessages = .shared) -> ChatsEntry {
        let newest = hidden.visible(thread.messages, in: thread.id) { $0.id }.last
        // Someone's emoji on a message after the newest one says more than that message itself.
        let reaction = thread.newestReaction
        let preview = reaction.map { $0.line(who: thread.isGroup ? shortSender($0.person) : "") } ?? newest.map(line) ?? ""
        let receipts = ChatReceipts.filled(thread.messages.map { ($0.isMine, $0.receipt) }, private: thread.isPrivate)
        let ticks = reaction != nil ? nil
            : ChatReceipts.newest(receipts, ids: thread.messages.map(\.id), shown: newest?.id).map(BubbleTicks.init)
        // A chat that was read in Nook is known to stand where Nook says, whatever its app tells.
        let readKnown = thread.readKnown != false || thread.readInNook != nil
        return ChatsEntry(id: thread.id, app: thread.app, name: thread.name, preview: preview,
                          last: max(thread.last, reaction?.date ?? .distantPast), read: thread.readState,
                          lastIsMine: reaction == nil && newest?.isMine ?? false, readKnown: readKnown, ticks: ticks,
                          members: thread.members, handle: thread.handle, avatar: thread.avatar,
                          account: thread.account ?? ChatLinker.shared.accountName(for: thread.app),
                          chatID: thread.chatID)
    }

    /// Of two threads holding the same newest message, the one to show: the one a bridge reads, else the fuller one.
    static func isBetter(_ thread: InboxThread, than other: InboxThread) -> Bool {
        let (bridged, otherBridged) = (thread.bridged == true, other.bridged == true)
        if bridged != otherBridged { return bridged }
        return thread.messages.count > other.messages.count
    }

    /// Who wrote in a group, as a chat list says it: the first name ("Henco" for "Henco Hendriksen"), so the message
    /// itself keeps the room. A phone number or a one-word name stays whole.
    static func shortSender(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("+"), let first = trimmed.split(separator: " ").first, first.count >= 2,
              first.count < trimmed.count, first.first?.isLetter == true else { return trimmed }
        return String(first)
    }

    /// A message as one line in the list, with who wrote it in a group ("Jan: dinner?").
    @MainActor
    static func line(_ message: InboxMessage) -> String {
        let who = message.isMine ? tr("chat.you") : shortSender(message.sender)
        return who.isEmpty ? message.summary : "\(who): \(message.summary)"
    }

    /// The chat as the Chats tab's search finds it: by its name or its people as it is, else by the newest of its
    /// messages that holds `needle`, which then shows as its line. Every message Nook has of it counts, not only the
    /// newest, so "dinner" finds the Instagram chat where it came up last week. Nil when nothing in it matches.
    @MainActor
    func found(_ needle: String, capture: ChatCaptureService) -> ChatsEntry? {
        if name.localizedCaseInsensitiveContains(needle) || preview.localizedCaseInsensitiveContains(needle)
            || (members ?? []).contains(where: { $0.localizedCaseInsensitiveContains(needle) }) {
            return self
        }
        guard let thread = capture.inbox.threads[id] else { return nil }
        let match = thread.messages.last { message in
            message.summary.localizedCaseInsensitiveContains(needle) || message.sender.localizedCaseInsensitiveContains(needle)
        }.map(Self.line)
        guard let match else { return nil }
        var entry = self
        entry.preview = match
        return entry
    }
}

/// `ChatsEntry.all`, made once and asked many times: the tab asks for it a dozen times while it draws (the list, the
/// filters, the counts, the open chat), and making it goes through every chat. Kept across redraws and forgotten as soon
/// as something it is made of changes (the chats, which apps are on, the chats you hid, the language; WhatsApp's linked
/// accounts and the chat helper's links by `visibility`), so a redraw for anything else (the panel, contact photos, the
/// app model) does not go through every chat again.
@MainActor
final class ChatsEntryMemo {
    private var entries: [ChatsEntry]?
    /// The inbox the list was made from (`ChatCaptureService.inboxRevision`). `objectWillChange` comes before a change:
    /// a list made again in that moment is of the chats as they were, and nothing would forget it after.
    private var revision: Int?
    private var watching: [AnyCancellable] = []
    /// What of WhatsApp's linked accounts and the chat helper decides which chats show (`ChatCaptureService.isShown`)
    /// and the account names the helper's chats carry, as they were when `entries` was made. Asked at each read instead
    /// of following their changes: they publish for every picture, name, read mark and send, and each made the whole
    /// list again while you scrolled it.
    private var visibility: [String] = []

    private static func visibility() -> [String] {
        WhatsAppAccounts.shared.links.map { "\($0.account):\($0.holdsChats)" } + ["\(ChatHelper.linked("whatsapp"))"]
            + ChatLinker.shared.networks.map { "\($0.app):\($0.accounts.first?.name ?? "")" }
    }

    func entries(capture: ChatCaptureService) -> [ChatsEntry] {
        let visibility = Self.visibility()
        if visibility != self.visibility { entries = nil }
        if let entries, revision == capture.inboxRevision { return entries }
        self.visibility = visibility
        if watching.isEmpty {
            // Which chats show also follows the linked WhatsApp accounts and the chats you hid.
            let changes: [AnyPublisher<Void, Never>] = [
                // The chats and which apps are on, not the rest of the service (its status, each bridge's last problem):
                // those change with every bridge read and would make the whole list again while you scroll it.
                capture.$inbox.map { _ in () }.eraseToAnyPublisher(),
                capture.$sources.map { _ in () }.eraseToAnyPublisher(),
                I18n.shared.objectWillChange.eraseToAnyPublisher(),
                ChatHiddenMessages.shared.objectWillChange.eraseToAnyPublisher(),
                ChatNoticeRulesStore.shared.objectWillChange.eraseToAnyPublisher(),
            ]
            // perf: only forgets the list (no state is written back), and every change must reach it.
            watching = changes.map { $0.sink { [weak self] _ in MainActor.assumeIsolated { self?.entries = nil } } }
        }
        let made = ChatsEntry.all(capture: capture)
        entries = made
        revision = capture.inboxRevision
        return made
    }
}


/// The open chat's bubbles, made again only when the chat, its fetched files or the language changed. Making them goes
/// through every message (and in a group names everyone who read yours), and the chat view asks for them several times
/// on each of its many redraws.
@MainActor
final class ChatBubblesMemo {
    private enum Source: Equatable {
        case thread(InboxThread?)
    }

    private var source: Source?
    private var language: AppLanguage?
    private var bubbles: [ChatBubble] = []

    /// The memos of the chats opened last, so going back to one shows it at once instead of making its bubbles again.
    private static var recent: [(chat: String, memo: ChatBubblesMemo)] = []
    private static let recentCount = 8

    /// The memo of `chat`, the one it had when it was open lately.
    static func kept(for chat: String) -> ChatBubblesMemo {
        let memo = recent.first { $0.chat == chat }?.memo ?? ChatBubblesMemo()
        recent.removeAll { $0.chat == chat }
        recent.insert((chat, memo), at: 0)
        if recent.count > recentCount { recent.removeLast() }
        return memo
    }

    /// The chat's bubbles, made again when the chat or the language changed. The pictures of its files are not part of
    /// them: each bubble loads its own once it comes into view.
    func bubbles(_ thread: InboxThread?, make: (InboxThread?) -> [ChatBubble]) -> [ChatBubble] {
        remembered(.thread(thread)) { make(thread) }
    }

    private func remembered(_ source: Source, make: () -> [ChatBubble]) -> [ChatBubble] {
        let language = I18n.shared.currentLanguage
        if source == self.source, language == self.language { return bubbles }
        bubbles = make()
        self.source = source
        self.language = language
        return bubbles
    }
}

/// `ChatsTab.shown`, kept while what it is made of stays the same. The body, the list, its empty note and the open chat
/// each ask for it, and while you search it reads every message of every chat: once per keystroke is enough.
@MainActor
final class ChatsShownMemo {
    private struct Key: Equatable {
        var all: [ChatsEntry]
        var needle: String
        var view: ChatsView
        var filter: String?
        var account: String?
        var selection: String?
        var kept: Set<String>
        /// The groups go by day ("Today", "Yesterday"), so a new day sorts again.
        var day: Date
    }

    private var key: Key?
    private var value: [ChatsEntry] = []
    /// `value` per group, in order, made with it.
    private(set) var sections: [ChatsSection] = []

    func shown(all: [ChatsEntry], needle: String, view: ChatsView, filter: String?, account: String?, selection: String?,
               kept: Set<String> = [], make: () -> [ChatsEntry]) -> [ChatsEntry] {
        let wanted = Key(all: all, needle: needle, view: view, filter: filter, account: account, selection: selection,
                         kept: kept, day: Calendar.current.startOfDay(for: Date()))
        if key == wanted { return value }
        value = make()
        key = wanted
        let now = Date()
        sections = []
        for entry in value {
            let group = ChatsGroup.of(entry, now: now)
            if sections.last?.group == group { sections[sections.count - 1].entries.append(entry) }
            else { sections.append(ChatsSection(group: group, entries: [entry])) }
        }
        return value
    }
}

/// The sidebar's counts (chats per view, new chats per app and per account), made again only when the chats or the
/// chosen app or account changed: the tab redraws for much else (a photo that came in, the panel around it).
@MainActor
final class ChatsCountsMemo {
    struct Counts {
        var views: [ChatsView: Int]
        var newByApp: [String: Int]
        var newByAccount: [String: Int]
    }

    private var key: (all: [ChatsEntry], filter: String?, account: String?)?
    private var value = Counts(views: [:], newByApp: [:], newByAccount: [:])

    func counts(all: [ChatsEntry], filter: String?, account: String?, make: () -> Counts) -> Counts {
        if let key, key.filter == filter, key.account == account, key.all == all { return value }
        value = make()
        key = (all, filter, account)
        return value
    }
}

/// Every chat in one place: WhatsApp (with a linked phone) and every other chat app on this Mac whose notifications
/// Nook collects or that Nook reads itself (Telegram, Instagram, Messenger, Signal, Messages…), all read the same way.
/// Three columns: a sidebar with the views (All chats, New, Only in Nook, Read) and the apps, the list of chats in groups
/// per day that fold shut, and the open chat with its bubbles, where it stands and its answer field. A chat you open is
/// read in Nook (which stays after a restart); "Mark as read in <app>" passes that on to the app itself.
/// Collecting is turned on in Settings › Connections › On your Mac › Chats.
struct ChatsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    /// Shows the panel footer at the foot of the leftmost column (under the sidebar's views and apps), where Agents has it
    /// under its sessions, so the refresh and update button sits in the same place on every tab. A footer page (pull requests, usage) opens on Agents through it.
    var openOnAgents: ((String) -> Void)?
    /// In the main window rather than the notch: each has its own open chat, read only while that one is in sight.
    var inWindow = false
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var whatsApp = WhatsAppAccounts.shared
    @ObservedObject private var photos = ContactPhotos.shared
    /// Who types where: each row gets its own line, so a row redraws only when its chat's line changed.
    @ObservedObject private var typing = ChatTypingCenter.shared
    /// The chats' own pictures, decoded off the main thread as their rows come into view.
    @ObservedObject private var avatars = ChatAvatarImages.shared
    /// The list scrolls to the open chat only when it was opened from elsewhere (the keyboard, a card, "@chat"): a click
    /// on a row that is in view already leaves the list where it is.
    @State private var revealSelection = false
    /// The chat closed with the back button while the tab shows one column: the list comes back scrolled to it.
    @State private var returnTo: String?
    /// The chats you opened or marked since the view, app or account last changed: they keep their place in a view they
    /// no longer match ("New" after reading one), so the rows under the pointer do not move up with every click.
    @State private var keptInView: Set<String> = []
    /// Brings the open chat into view in the list again, when it was asked for while open already.
    @State private var revealAgain = 0
    /// When the open chat was opened: a "Mark as unread" after that (in the other surface, on the iPhone) is not read
    /// again just because it is open here.
    @State private var openedAt = Date()
    /// The list is scrolling: a row the pointer rests on meanwhile fetches nothing (`ChatsRow`).
    @MainActor static var listScrolling = false
    /// The open chat: the one you opened last, also after the tab was closed or Nook restarted; nil shows none.
    @State private var selection: String? = ChatsTab.lastOpened
    /// One app's chats only (its source id), or all.
    @State private var filter: String?
    /// Within the chosen app, one of its accounts only (by its name), while the app has chats in more than one.
    @State private var account: String?
    /// Which chats the list shows by where they stand; the chat you opened stays while you read it.
    @AppStorage("nook.chats.view") private var view: ChatsView = .all
    @State private var query = ""
    /// The groups folded shut (a click on their header); a search shows every group open.
    @State private var collapsed: Set<ChatsGroup> = []
    @AppStorage("nook.chats.listWidth") private var listWidth = PanelLayout.chatsList
    /// How wide the sidebar is after you dragged its line, like every other line between panels; 0 follows the panel
    /// (a rail when it is narrow). A double-click on the line goes back to that. Remembered.
    @AppStorage("nook.chats.sidebarWidth") private var sidebarChoice: Double = 0
    @State private var sidebarDragStart: Double?
    /// The sidebar's width while its line is dragged (`PanelDrag`).
    @State private var liveSidebar: Double?
    private var sidebarSize: Double { liveSidebar ?? sidebarChoice }
    /// Settings › Connections: opening a chat reads it in Nook. On by default; the app itself hears it only from your click.
    @AppStorage(ChatsTab.readOnOpenKey) private var readOnOpen = true
    @State private var totalWidth: Double = 0
    @State private var entriesMemo = ChatsEntryMemo()
    @State private var shownMemo = ChatsShownMemo()
    @State private var countsMemo = ChatsCountsMemo()

    static let readOnOpenKey = "nook.chats.readOnOpen"
    /// The apps Nook can link so that it writes in their chats: through its chat helper, or a bridge of its own.
    static let linkableApps = ChatHelper.apps.union(["teams", "snapchat", MailChatData.app])

    /// The chat you opened last, kept for the next time the tab opens.
    static var lastOpened: String? {
        get { UserDefaults.standard.string(forKey: "nook.chats.lastOpened").map(ChatIDMigration.current) }
        set { UserDefaults.standard.set(newValue, forKey: "nook.chats.lastOpened") }
    }

    /// Unread messages in every chat, for the dot on the tab.
    @MainActor
    static var unread: Int {
        ChatCaptureService.shared.visibleUnread
    }

    /// The sidebar folds to a rail of icons when the panel is narrow, so the list and the chat keep their room.
    /// Dragged narrower than `chatsSidebarFold`, it is the rail too.
    private var compactSidebar: Bool {
        if sidebarSize > 0 { return sidebarSize < PanelLayout.chatsSidebarFold }
        return totalWidth > 0 && totalWidth < PanelLayout.chatsSidebarRoom
    }
    private var sidebarWidth: Double {
        if compactSidebar { return Double(PanelLayout.chatsRail) }
        guard sidebarSize > 0 else { return Double(PanelLayout.chatsSidebar) }
        // However wide you made it, the list keeps its narrowest width beside it.
        let room = totalWidth > 0 ? totalWidth - PanelLayout.minimumList - PanelSplit.handle : PanelLayout.chatsSidebarMax
        return max(PanelLayout.chatsSidebarFold, min(sidebarSize, PanelLayout.chatsSidebarMax, room))
    }
    /// Too narrow for the list and a chat side by side: one of them at a time (`PanelLayout.stacks`).
    private var stacked: Bool { PanelLayout.stacks(totalWidth - sidebarWidth) }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if capture.status == .needsAccess { accessBar }
            if case .failed(let why) = capture.status { failedBar(why) }
            if all.isEmpty {
                empty
                // No list yet: the footer keeps the list's width at the bottom.
                if showsFooter { footer.frame(width: min(listWidth, max(totalWidth, PanelLayout.minimumList))) }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    // Too narrow for both (split view, a small window): the open chat over the whole width with a back
                    // button, else the sidebar and the list.
                    if !stacked || current == nil {
                        sidebar
                        sidebarHandle
                        // The same split as the Agents tab: a list you can widen, a line, and the open chat beside it.
                        list
                            .padding(.leading, NookTheme.Spacing.md)
                            .listPanel(stacked: stacked, width: $listWidth, defaultWidth: PanelLayout.chatsList,
                                       available: max(totalWidth - sidebarWidth, 0),
                                       rest: PanelLayout.minimumConversation + PanelSplit.handle)
                    }
                    if !stacked || current != nil {
                        Group {
                            if let current {
                                ChatsDetail(entry: current, photo: photo(current), capture: capture,
                                            onMarkUnread: { markUnread(current) }, onClose: closeChat,
                                            onBack: stacked ? closeChat : nil)
                                    .equatable()
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
                        .padding(.leading, stacked ? 0 : NookTheme.Spacing.lg)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .animation(NookTheme.reveal, value: stacked && current != nil)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .onAppear {
            takeFocus()
            photos.refresh()
        }
        // The pictures of the chats in the list whose app gives them on request, newest first, as their app shows them.
        // Again once a linked account's list of chats came in. Only once the switch to this tab has settled, as on Agents.
        .task(id: whatsApp.connected.map { "\($0.account) \($0.knownChats.count)" }.joined(separator: ",")) {
            try? await Task.sleep(for: NookTheme.tabSettle)
            guard !Task.isCancelled else { return }
            await app.loadChatAvatars(all)
        }
        // ⌘⇧[ and ⌘⇧] go to the chat above or below in the list, as they go through sessions on Agents.
        .keyCommands(["session.previous": { step(-1) }, "session.next": { step(1) }], enabled: !all.isEmpty)
        .onChange(of: viewModel.chatsFocus) { _, _ in takeFocus() }
        // Another app (or none) has accounts of its own: the account chosen before no longer applies.
        .onChange(of: filter) { _, _ in
            account = nil
            keptInView = []
        }
        .onChange(of: view) { _, _ in keptInView = [] }
        .onChange(of: account) { _, _ in keptInView = [] }
        .onChange(of: selection) { old, id in
            ChatsTab.lastOpened = id
            openedAt = Date()
            if let old { keptInView.insert(old) }
        }
        // With "Read in Nook when opened" on, a chat you open is read in Nook, and so is what comes in while it is open:
        // its badge goes and stays gone after a restart. The app itself (and whoever wrote) hears nothing until you
        // choose "Mark as read in <app>". The same for every app.
        .onChange(of: current.map { "\($0.id) \($0.unread)" }, initial: true) { _, _ in readOpenChat() }
        // The main window that opened behind the app you were in (at login) is read once you come to it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in readOpenChat() }
    }

    /// Reads the open chat in Nook, only while you can be looking at this one: in the open notch, or in the main window
    /// while that is in front. A window that opened behind the app you are in leaves it unread.
    private func readOpenChat() {
        guard readOnOpen, app.viewModel.isShowing(.inbox, inWindow: inWindow), let entry = current, entry.read.isUnread else { return }
        // Marked unread by hand while it was open here (from the notch, the main window, the iPhone): it stays so.
        if let marked = capture.markedUnread(entry.id), marked > openedAt { return }
        app.markChatReadInNook(entry)
    }

    private var showsFooter: Bool { openOnAgents != nil && !app.demoMode }

    @ViewBuilder
    private var footer: some View {
        if let openOnAgents, showsFooter {
            PanelFooter(selected: "", open: openOnAgents, openSettings: { app.openSettings() }, history: app.history,
                        vertical: compactSidebar && !all.isEmpty)
        }
    }

    /// Opens the chat `offset` rows from the open one in the list (the first one when none is open). False at either end.
    private func step(_ offset: Int) -> Bool {
        let rows = shown.filter { searching || !collapsed.contains(ChatsGroup.of($0, now: Date())) }
        guard !rows.isEmpty else { return false }
        let index = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(next) else { return false }
        revealSelection = true
        selection = rows[next].id
        return true
    }

    /// Escape (see `ChatsDetail`): the open chat closes; the list stays.
    private func closeChat() {
        guard selection != nil else { return }
        if stacked { returnTo = selection }
        withAnimation(NookTheme.reveal) { selection = nil }
    }

    /// "Mark as unread", by hand, in Nook only: the badge comes back, and an open chat closes so that opening it again
    /// reads it.
    private func markUnread(_ entry: ChatsEntry) {
        keptInView.insert(entry.id)
        if selection == entry.id {
            if stacked { returnTo = entry.id }
            withAnimation(NookTheme.reveal) { selection = nil }
        }
        app.markChatUnread(entry)
    }

    /// Shows what "@chat …" asked for.
    private func takeFocus() {
        guard let focus = viewModel.chatsFocus else { return }
        viewModel.chatsFocus = nil
        filter = focus.app
        account = nil
        view = .all
        query = focus.query
        let chat = focus.chat.map(ChatIDMigration.current)
        revealSelection = true
        // Already open: the selection does not change, so the list is asked to bring it into view itself.
        if chat != nil, chat == selection { revealAgain += 1 }
        selection = chat
        collapsed = []
        keptInView = []
    }

    // MARK: The chats

    /// Every chat, newest first, as `ChatsEntry.all` lists them: made once per redraw (see `ChatsEntryMemo`).
    private var all: [ChatsEntry] { entriesMemo.entries(capture: capture) }

    private func photo(_ entry: ChatsEntry) -> NSImage? {
        // Straight to the image cache: a file check first cost a disk lookup per row on every redraw of the list. A
        // missing file gives no image either way.
        // Decoded off the main thread the first time (`ChatAvatarImages`): scrolling to rows not seen yet decodes nothing
        // here.
        if let avatar = entry.avatar, let image = avatars.image(avatar) {
            return image
        }
        return photos.photo(handle: entry.handle, name: entry.name)
    }

    /// The chats of the chosen app (or every app), and of its chosen account, before the view and the search narrow them.
    private var inApp: [ChatsEntry] {
        guard let filter else { return all }
        let chosen = shownAccount
        return all.filter { $0.app == filter && (chosen == nil || $0.account == chosen) }
    }

    /// The accounts of the chosen app that have chats here, by name, while there is more than one; empty otherwise.
    /// The same for every app whose chats say which account they are in (WhatsApp with several phones linked).
    private var accounts: [String] {
        guard let filter else { return [] }
        let names = Set(all.lazy.filter { $0.app == filter }.compactMap(\.account))
        return names.count > 1 ? names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } : []
    }

    /// The account the list narrows to: the chosen one, as long as the chosen app still has chats in it.
    private var shownAccount: String? { account.flatMap { accounts.contains($0) ? $0 : nil } }

    /// Chats with something new per account of the chosen app.
    private var newByAccount: [String: Int] { counts.newByAccount }

    private var counts: ChatsCountsMemo.Counts {
        countsMemo.counts(all: all, filter: filter, account: shownAccount) {
            ChatsCountsMemo.Counts(views: makeViewCounts(), newByApp: makeNewByApp(), newByAccount: makeNewByAccount())
        }
    }

    private func makeNewByAccount() -> [String: Int] {
        guard let filter else { return [:] }
        let fresh = all.filter { $0.app == filter && $0.read.isUnread }
        return Dictionary(grouping: fresh.compactMap(\.account), by: { $0 }).mapValues(\.count)
    }

    /// The chats that match the view, the app and the search (their names, their people and every message Nook has of
    /// them), in the list's order: group by group, newest first in each. A chat keeps its place when it is read, and the
    /// open one stays in the view while you read it, so nothing jumps.
    private var shown: [ChatsEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return shownMemo.shown(all: all, needle: needle, view: view, filter: filter, account: shownAccount,
                               selection: selection, kept: keptInView) { makeShown(needle) }
    }

    private func makeShown(_ needle: String) -> [ChatsEntry] {
        let now = Date()
        let found = needle.isEmpty ? inApp : inApp.compactMap { $0.found(needle, capture: capture) }
        return found.filter { view.shows($0.read) || $0.id == selection || keptInView.contains($0.id) }
            .map { (entry: $0, group: ChatsGroup.of($0, now: now)) }
            .sorted { a, b in
                if a.group != b.group { return a.group < b.group }
                return a.entry.last != b.entry.last ? a.entry.last > b.entry.last : a.entry.id < b.entry.id
            }
            .map(\.entry)
    }

    /// The shown chats per group, in order; empty groups left out.
    private var sections: [ChatsSection] {
        _ = shown
        return shownMemo.sections
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The chat on the right: the one you opened, as long as the list shows it; none until you open one.
    private var current: ChatsEntry? {
        guard let selection else { return nil }
        return shown.first { $0.id == selection }
    }

    /// How many chats each view holds, in the chosen app.
    private var viewCounts: [ChatsView: Int] { counts.views }

    private func makeViewCounts() -> [ChatsView: Int] {
        var counts: [ChatsView: Int] = [:]
        for item in ChatsView.allCases { counts[item] = inApp.filter { item.shows($0.read) }.count }
        return counts
    }

    /// Chats with something new, per app.
    private var newByApp: [String: Int] { counts.newByApp }

    private func makeNewByApp() -> [String: Int] {
        Dictionary(grouping: all.filter { $0.read.isUnread }, by: \.app).mapValues(\.count)
    }

    /// The apps that have chats here: the ones with something new first, then the busiest, and the one filtered on
    /// even when it has none yet. After them every source that is on and on this Mac (its app is installed, you added it
    /// yourself, or Nook reads it with your login, as Instagram), also before it brought in a message: a source you switched
    /// on shows up here, not only once it has chats.
    private var apps: [String] {
        let counts = Dictionary(grouping: all, by: \.app).mapValues(\.count)
        let fresh = newByApp
        var result = counts.keys.sorted { a, b in
            let (fa, fb) = (fresh[a] ?? 0, fresh[b] ?? 0)
            if (fa > 0) != (fb > 0) { return fa > 0 }
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
    /// (LinkedIn, X…) wait until they bring in a chat, or the sidebar would list every app Nook knows.
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

    /// The leftmost column: the views and apps, and under them the panel footer (settings, pull requests, usage, refresh),
    /// as wide as the sidebar, or one icon under the other in the rail.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ChatsSidebar(compact: compactSidebar, width: sidebarWidth, view: $view, app: $filter, account: $account, counts: viewCounts, apps: apps,
                         newByApp: newByApp, accounts: accounts, newByAccount: newByAccount,
                         addSource: { app.openConnections(.add(.chats)) })
            footer
                .frame(width: sidebarWidth)
        }
        .padding(.trailing, compactSidebar ? NookTheme.Spacing.xs : NookTheme.Spacing.sm)
    }

    /// The line between the sidebar and the list, a drag line like every other one between panels: drag it to make the
    /// sidebar wider or narrower (narrow enough and it folds to the rail, wide enough and it opens again), double-click
    /// it to let the panel's width decide again.
    private var sidebarHandle: some View {
        EmbeddedSplitHandle(
            divider: true,
            help: "panel.resize",
            onDrag: { offset in
                let start = sidebarDragStart ?? sidebarWidth
                sidebarDragStart = start
                let dragged = start + offset
                PanelDrag.step($liveSidebar, to: dragged < PanelLayout.chatsSidebarFold
                    ? Double(PanelLayout.chatsRail) : min(dragged, PanelLayout.chatsSidebarMax))
            },
            onEnd: {
                sidebarDragStart = nil
                PanelDrag.commit($liveSidebar, to: $sidebarChoice)
            },
            onReset: { withAnimation(NookTheme.reveal) { sidebarChoice = 0 } }
        )
    }

    /// The list's title: the view, and the app when one is chosen ("New · Telegram"), and its account when one is
    /// ("New · WhatsApp · Business"), with the one action that fits it.
    private var listTitle: String {
        let appName = filter.map { MessagingApps.app(id: $0)?.name ?? $0 }
        return [view.title, appName, shownAccount].compactMap { $0 }.joined(separator: " · ")
    }

    private var listHeader: some View {
        let fresh = inApp.filter { $0.read.isUnread }
        return PanelListHeader(listTitle) {
            if !fresh.isEmpty {
                ToolbarIconButton("checkmark.circle", tr("chats.markAllReadInNook")) { app.markAllChatsReadInNook(fresh) }
            }
        }
    }

    private var searchField: some View {
        NookSearchField(prompt: tr("chats.search"), text: $query)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            listHeader
            searchField

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: NookTheme.Spacing.xxs) {
                    let selected = current?.id
                    let groups = sections
                    let typists = typing.state
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
                                // One view per chat: a lazy stack whose rows bring a separator only sometimes loses
                                // track of a row that moves to the top of its group, and kept showing its old line.
                                VStack(spacing: NookTheme.Spacing.xxs) {
                                    if entry.id != section.entries.first?.id { NookRowSeparator() }
                                    ChatsRow(entry: entry, photo: photo(entry), selected: entry.id == selected,
                                             typing: typists.chats.isEmpty ? nil : typing.line(entry.id),
                                             rowAction: rowAction(entry)) {
                                        revealSelection = false
                                        selection = entry.id
                                    }
                                        .equatable()
                                        .contextMenu { readMenu(entry) }
                                }
                                .id(entry.id)
                            }
                        }
                    }
                }
            }
            // A chat opened from elsewhere (the keyboard, a card, search) is brought into view in the list. A click on a
            // row does not move the list: scrolling a lazy list to a row it already shows could jump it to the top.
            .onChange(of: selection) { _, id in
                guard revealSelection else { return }
                revealSelection = false
                guard let id else { return }
                // Once the list shows it (a folded group opens, a search ends) and the rows around it are laid out.
                DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: revealAgain) { _, _ in
                guard revealSelection, let id = selection else { return }
                revealSelection = false
                DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onScrollPhaseChange { _, phase in ChatsTab.listScrolling = phase != .idle }
            // A list that goes while it scrolls leaves no other list without its hover fetch.
            .onDisappear { ChatsTab.listScrolling = false }
            // Back from a chat while one column shows at a time: the list is where you left it, at that chat.
            .onAppear {
                guard let id = returnTo ?? (revealSelection ? selection : nil) else { return }
                returnTo = nil
                revealSelection = false
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
            }
            }
            if shown.isEmpty { emptyList }
            listHints
        }
    }

    /// The one step a row offers under the pointer: read what is new in Nook, pass a chat read in Nook on to its app,
    /// or make a chat that is read everywhere unread again.
    private func rowAction(_ entry: ChatsEntry) -> ChatsRowAction {
        let appName = MessagingApps.app(id: entry.app)?.name ?? entry.app
        switch entry.read {
        case .unread:
            return ChatsRowAction(to: .readInNook, title: tr("chats.row.markRead"), label: tr("chats.markReadInNook")) {
                keptInView.insert(entry.id)
                app.markChatReadInNook(entry)
            }
        case .readInNook:
            return ChatsRowAction(to: .read, title: tr("chats.row.markReadInApp", appName),
                                  label: tr("chats.markReadInApp", appName)) {
                keptInView.insert(entry.id)
                app.markChatReadInApp(entry)
            }
        case .read:
            return ChatsRowAction(to: .unread(1), title: tr("chats.row.markUnread"), label: tr("chats.markUnread")) {
                markUnread(entry)
            }
        }
    }

    /// Read and unread for a chat, the same in its row's menu and its "…" menu: what applies to where it stands.
    @ViewBuilder
    private func readMenu(_ entry: ChatsEntry) -> some View {
        let appName = MessagingApps.app(id: entry.app)?.name ?? entry.app
        if entry.read.isUnread {
            Button(tr("chats.markReadInNook")) { app.markChatReadInNook(entry) }
        }
        if entry.read != .read {
            Button(tr("chats.markReadInApp", appName)) { app.markChatReadInApp(entry) }
        }
        if !entry.read.isUnread {
            Button(tr("chats.markUnread")) { markUnread(entry) }
        }
    }

    /// The list is empty for what the sidebar chose: why, and one click to what there is.
    @ViewBuilder
    private var emptyList: some View {
        if !searching, view != .all {
            VStack(spacing: NookTheme.Spacing.sm) {
                ListEmptyNote(tr("chats.view.empty." + view.rawValue))
                SmallGhostButton(title: tr("chats.unread.showAll")) { withAnimation(NookTheme.swap) { view = .all } }
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
                    // Slack, Telegram, Teams and the chat helper's apps keep their history elsewhere: connected once, Nook reads it from
                    // there.
                    ListEmptyNote(tr("chats.\(bridge.app).connectHint"))
                    SmallGhostButton(title: tr("chats.\(bridge.app).connect")) { app.openConnections(.chat(bridge.app)) }
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
                    SmallGhostButton(title: tr("chats.addMore")) { app.openConnections(.add(.chats)) }
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
                    NookGhostButton(title: tr("chats.empty.setup"), symbol: "gearshape") { app.openConnections(.add(.chats)) }
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

/// A group of the list: by when a chat last moved, as every chat app has it. What is new stands out in its row and
/// under "New" in the sidebar, so reading a chat never moves it.
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

/// The one step a chat's row offers while the pointer is on it (see `ChatsTab.rowAction`).
struct ChatsRowAction {
    /// Where the chat stands after the click: the button shows that mark.
    let to: ChatReadState
    /// The short word on the button ("Read", "Read in WhatsApp", "Unread").
    let title: String
    /// The whole step, as the tooltip and VoiceOver say it.
    let label: String
    let perform: () -> Void
}

/// A chat in the list: its picture with its app's icon, its name, when, the newest message, and where it stands at the
/// end of that line: the count of what is new, one tick for read in Nook, two for read in the app too.
private struct ChatsRow: View, Equatable {
    let entry: ChatsEntry
    let photo: NSImage?
    let selected: Bool
    /// Who types in this chat ("Jan is typing…"), in place of its newest message; nil while no one does.
    var typing: String? = nil
    /// What a click on the button that shows under the pointer does.
    var rowAction: ChatsRowAction? = nil
    let action: () -> Void
    @State private var hovering = false
    /// What the pointer resting here fetches. The row asks `AppModel.shared` without observing it, so it does not redraw
    /// with every change of the app model.
    @State private var prefetch: Task<Void, Never>?
    /// A row is drawn again only when what it shows changed: the list redraws for much else (a bridge that read, the
    /// row under the pointer), and drawing every row again each time made scrolling stutter. The actions follow the
    /// entry, so an equal entry has the same ones.
    static func == (lhs: ChatsRow, rhs: ChatsRow) -> Bool {
        lhs.entry == rhs.entry && lhs.photo === rhs.photo && lhs.selected == rhs.selected && lhs.typing == rhs.typing
            && lhs.rowAction?.title == rhs.rowAction?.title
    }

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
            row.accessibilityAction(named: Text(rowAction?.label ?? "")) { rowAction?.perform() }
            // As the Nook and agent lists have it: the row's action where its time was, while the pointer is on it.
            if let rowAction {
                ChatMarkButton(to: rowAction.to, title: rowAction.title, help: rowAction.label, compact: true,
                               action: rowAction.perform)
                    .pointerStyle(.link)
                    .rowActionsBackdrop(NookTheme.rowFill(selected: selected, hovering: true, rest: .clear))
                    .padding(.top, NookTheme.Spacing.sm)
                    .padding(.trailing, NookTheme.Spacing.sm)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .accessibilityHidden(true)
            }
        }
        // A row without a line under its name gets its newest message fetched.
        .onAppear { AppModel.shared.loadChatLine(entry) }
        .onHover { inside in
            hovering = inside
            // What the click needs is fetched once the pointer rests on the chat, so it opens filled; passing over the
            // list on the way elsewhere fetches nothing.
            prefetch?.cancel()
            prefetch = nil
            // Rows sliding under a pointer that stands still while the list scrolls fetch nothing.
            if inside, !ChatsTab.listScrolling {
                let entry = self.entry
                prefetch = Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled, !ChatsTab.listScrolling else { return }
                    await AppModel.shared.prefetchChat(entry)
                }
            }
        }
        .animation(NookTheme.hover, value: hovering)
    }

    /// The newest message as the row shows it: after your own message's ticks without "You:", which the ticks say.
    private var previewText: String {
        let mine = tr("chat.you") + ": "
        guard entry.ticks != nil, entry.preview.hasPrefix(mine) else { return entry.preview }
        return String(entry.preview.dropFirst(mine.count))
    }

    /// Where the chat stands, in words, for VoiceOver.
    private var stateLabel: String {
        switch entry.read {
        case .unread(let count): return tr("chats.status.unread", count)
        case .readInNook: return tr("chats.legend.readInNook")
        case .read: return tr("chats.legend.read")
        }
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 40)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    // One title line (who, when) and one line under it (the newest message); unread is said once, by
                    // the count at the end of the second line.
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                        Text(entry.name)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(entry.read.isUnread ? NookTheme.paper : NookTheme.textStrong)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.xs)
                        // The WhatsApp account, while more than one is linked.
                        if let account = entry.account {
                            Text(account)
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.textTertiary)
                                .lineLimit(1)
                                .opacity(hovering && rowAction != nil ? 0 : 1)
                        }
                        // Something new: its time in the color of what waits on you, as the count under it.
                        Text(when)
                            .font(NookTheme.TextStyle.caption)
                            .monospacedDigit()
                            .foregroundStyle(entry.read.isUnread ? NookTheme.amber : NookTheme.textTertiary)
                            .fixedSize()
                            .opacity(hovering && rowAction != nil ? 0 : 1)
                    }
                    HStack(spacing: NookTheme.Spacing.sm) {
                        if let ticks = entry.ticks, typing == nil { TicksView(ticks: ticks) }
                        if let typingLine = typing {
                            Text(typingLine)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.mint)
                                .lineLimit(1)
                        } else {
                            // A chat on the phone that wrote nothing since Nook was linked: its messages load when opened.
                            Text(entry.preview.isEmpty ? tr("chats.row.load") : previewText)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(entry.preview.isEmpty ? NookTheme.textTertiary
                                                 : (entry.read.isUnread ? NookTheme.textStrong : NookTheme.textSecondary))
                                .lineLimit(1)
                        }
                        Spacer(minLength: NookTheme.Spacing.xs)
                        // Where it stands, the same mark for every app; your own newest message has its ticks in front.
                        if entry.showsReadMark {
                            ChatReadMark(state: entry.read)
                                .fixedSize()
                        }
                    }
                }
            }
            // The avatar lines up with the list's title and its group names above it.
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .selectionMark(selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\([MessagingApps.app(id: entry.app)?.name ?? entry.app, entry.account].compactMap { $0 }.joined(separator: " "))"
                            + ", \(entry.name), \(stateLabel): \(entry.preview)")
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
private struct ChatsDetail: View, Equatable {
    let entry: ChatsEntry
    let photo: NSImage?
    @ObservedObject var capture: ChatCaptureService
    /// What a linked WhatsApp account can do now (edit, pin, vote…) is part of what this chat offers.
    @ObservedObject private var whatsApp = WhatsAppAccounts.shared
    /// "Mark as unread" in the header: the tab closes the chat and shows its badge again.
    var onMarkUnread: () -> Void = {}
    /// Escape: the tab closes the chat.
    var onClose: () -> Void = {}
    /// Back to the list, while the tab shows one column at a time; nil while the list sits beside the chat.
    var onBack: (() -> Void)? = nil
    @EnvironmentObject private var app: AppModel
    @State private var reply = ""
    @State private var notice: String?
    /// The sends still going to the chat, one after another: each waits for the one before it, so messages arrive in
    /// the order you sent them while the field is free for the next one at once.
    @State private var sending: Task<Void, Never>?
    @FocusState private var replyFocused: Bool
    /// A photo shown big over the chat, until it is clicked or Escape is pressed.
    @State private var zoomed: ChatBubble?
    /// The message the field answers, quoted above it until it is sent or let go.
    @State private var replyingTo: ChatBubble?
    /// Your message whose text the field changes, shown above it until the change goes or is let go.
    @State private var editing: ChatBubble?
    /// The message whose deletion waits for your choice: for you, or for everyone.
    @State private var deleting: ChatBubble?
    /// Messages you deleted for yourself, which this chat no longer shows.
    @ObservedObject private var hiddenMessages = ChatHiddenMessages.shared
    @State private var bubblesMemo: ChatBubblesMemo
    /// What you sent that its app has not shown back yet: it is in the chat at once.
    @ObservedObject private var outbox = ChatOutbox.shared
    /// Who is typing in this chat, under its last message.
    @ObservedObject private var typing = ChatTypingCenter.shared
    /// The collected chat whose removal waits for a yes.
    @State private var removing: String?
    /// The chats Nook writes in through the linked chat service, for what can be done in this one.
    @ObservedObject private var linked = ChatCaptureService.shared.serviceBridge
    /// Files waiting to go, the poll, place, contact or sticker panel, and the voice recorder.
    @StateObject private var composer = ChatComposerModel()
    /// How many messages were new when the chat opened (before opening read them), and the first of them once the chat
    /// shows them: the transcript draws "New messages" above it.
    @State private var unreadAtOpen: Int
    @State private var newFrom: String?

    init(entry: ChatsEntry, photo: NSImage?, capture: ChatCaptureService,
         onMarkUnread: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}, onBack: (() -> Void)? = nil) {
        self.entry = entry
        self.photo = photo
        self.capture = capture
        self.onMarkUnread = onMarkUnread
        self.onClose = onClose
        self.onBack = onBack
        _unreadAtOpen = State(initialValue: entry.unread)
        _bubblesMemo = State(initialValue: ChatBubblesMemo.kept(for: entry.id))
    }

    /// The open chat is drawn again for its own changes (what it observes) and when it shows another state of its chat;
    /// a redraw of the tab around it (the list scrolling, a picture in a row, a typing line in another chat) leaves it
    /// alone. The closures do the same for the same chat.
    static func == (lhs: ChatsDetail, rhs: ChatsDetail) -> Bool {
        lhs.entry == rhs.entry && lhs.photo === rhs.photo && (lhs.onBack == nil) == (rhs.onBack == nil)
            && lhs.language == rhs.language
    }

    /// The language the chat is drawn in: a change of it draws the chat again.
    let language = I18n.shared.currentLanguage

    /// Places "New messages" above the first of what was new, once the chat shows it.
    private func landNew() {
        guard newFrom == nil, unreadAtOpen > 0 else { return }
        let incoming = bubbles.filter { !$0.fromMe }
        guard incoming.count >= unreadAtOpen else { return }
        newFrom = incoming[incoming.count - unreadAtOpen].id
        unreadAtOpen = 0
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The key of a chat's unsent answer in `ComposerDraftStore`.
    private static func draftKey(_ chatID: String) -> String { "chat:" + chatID }

    /// What you were typing to a chat, also under the id it had before WhatsApp joined the shared inbox.
    private static func draft(_ chatID: String) -> String? {
        ComposerDraftStore.shared.draft(for: draftKey(chatID))
            ?? ChatIDMigration.previous(chatID).flatMap { ComposerDraftStore.shared.draft(for: draftKey($0)) }
    }

    private var appName: String { MessagingApps.app(id: entry.app)?.name ?? entry.app }

    /// The app as the header names it, with the WhatsApp account while more than one is linked ("WhatsApp · Business").
    private var appLine: String { entry.account.map { appName + " · " + $0 } ?? appName }

    /// Where what you send goes: WhatsApp, Telegram or Nook's chat helper; nil copies the text for the chat's own app.
    private var route: ChatRoute? { app.chatRoute(for: entry) }

    /// The apps whose "Nook can only read this" line you put away, by id, comma-separated.
    @AppStorage("nook.chats.limitsHidden") private var limitsHidden = ""

    /// A chat Nook can only read says so above its field, with the step that lets Nook write in it; nil where Nook writes.
    private func limitsLine(route: ChatRoute?) -> AnyView? {
        guard route == nil, !limitsHidden.split(separator: ",").contains(Substring(entry.app)) else { return nil }
        let id = entry.app
        return AnyView(ChatLimitsLine(appName: appName, linkable: ChatsTab.linkableApps.contains(id),
                                      link: { app.openConnections(.chat(id)) },
                                      openApp: { app.openChatApp(id) },
                                      dismiss: { withAnimation(NookTheme.reveal) { limitsHidden += (limitsHidden.isEmpty ? "" : ",") + id } }))
    }

    /// What Nook can do in this chat, the same list for every app.
    private var abilities: ChatAbilities { app.chatAbilities(route) }

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
        let all = bubblesMemo.bubbles(capture.inbox.threads[entry.id]) { thread in
            thread.map { ChatBubble.bubbles($0) { Self.time.string(from: $0) } } ?? []
        }
        return outbox.bubbles(hiddenMessages.visible(all, in: entry.id) { $0.id }, chat: entry.id)
    }

    /// "For everyone" is offered for your own message in an app that takes it; "for me" for every message.
    private func canDeleteForEveryone(_ bubble: ChatBubble) -> Bool { bubble.fromMe && abilities.delete && route != nil }

    /// What the choice says each way does, in this chat's app.
    private func deleteDetail(_ bubble: ChatBubble) -> String {
        var forMe: String
        forMe = abilities.deleteForMe ? tr("chat.delete.forMe.app", appName) : tr("chat.delete.forMe.local", appName)
        if canDeleteForEveryone(bubble) { forMe += "\n\n" + tr("chat.delete.forEveryone.detail", appName) }
        return forMe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, NookTheme.Spacing.md)
            NookDivider()
            // The messages and the field take the whole width, as a chat app's do: theirs on the left edge, yours on the
            // right. Each bubble stays narrow enough to read (`ChatBubbleView.maxWidth`), however wide the window is.
            VStack(spacing: 0) {
                if bubbles.isEmpty { emptyChat }
                ChatTranscript(bubbles: bubbles, contact: entry.name, fills: true,
                               onOpen: { open($0) }, onZoom: { zoom($0) },
                               onReply: abilities.reply ? quote : nil,
                               onReact: abilities.react ? react : nil,
                               onEdit: abilities.edit ? edit : nil,
                               onDelete: { deleting = $0 },
                               onVote: canVote ? vote : nil, onLoadOlder: canLoadOlder ? loadOlder : nil,
                               typing: typing.line(entry.id), newFrom: newFrom)
                    .equatable()
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
                    .padding(.top, NookTheme.Spacing.sm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if let zoomed, case .photo(let url) = zoomed.media, let image = zoomed.image ?? ChatMediaImages.image(url) {
                ChatPhotoZoom(url: url, preview: image, name: zoomed.attachment ?? "",
                              onClose: { withAnimation(NookTheme.reveal) { self.zoomed = nil } },
                              onOpen: { self.zoomed = nil; open(zoomed) })
                    .transition(.opacity)
            }
        }
        // Deleting asks how: for you (every app; it leaves Nook on this Mac, and Telegram for you), or for everyone (your
        // own message, in an app that takes it).
        .confirmationDialog(tr("chat.delete.choose"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { bubble in
            if canDeleteForEveryone(bubble) {
                Button(tr("chat.delete"), role: .destructive) { delete(bubble) }
            }
            Button(tr("chat.delete.forMe"), role: .destructive) {
                withAnimation(NookTheme.reveal) {
                    app.deleteInChatForMe(bubble, route: route, chat: entry.id, name: entry.name)
                }
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: { bubble in
            Text(deleteDetail(bubble))
        }
        .task(id: entry.id) {
            // Every app the same: an opened chat is read from its app now, so it shows the newest messages at once.
            landNew()
            await app.openedChat(entry)
            landNew()
        }
        // While a chat is open Nook is online in it where its app needs that to say who types (WhatsApp).
        .onAppear { app.setChatOnline(entry) }
        .onDisappear { app.setChatOnline(nil) }
        // Nothing waiting for one chat goes to the next.
        .onChange(of: entry.id) { _, id in
            app.setChatOnline(entry)
            composer.reset()
            editing = nil
            reply = Self.draft(id) ?? ""
            replyFocused = true
        }
        // What you were typing to this chat stays when the notch closes, and comes back when you open the chat again.
        // An opened chat puts the cursor in the field, after a brief wait for the panel to take the keyboard.
        .onAppear {
            if reply.isEmpty, let saved = Self.draft(entry.id) { reply = saved }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { replyFocused = true }
        }
        // The panel can take the keyboard after the chat appeared: the field asks again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is NotchPanel, !replyFocused, zoomed == nil, composer.panel == nil else { return }
            replyFocused = true
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
        guard case .photo(let url) = bubble.media, bubble.image ?? ChatMediaImages.image(url) != nil else { return open(bubble) }
        withAnimation(NookTheme.reveal) { zoomed = bubble }
    }

    /// Whether a poll in this chat can be voted on from here, as its app allows (`ChatAbilities.vote`).
    private var canVote: Bool { abilities.vote }

    /// Your vote on a poll, after your own click; when it cannot go, the chat says so and the poll shows the old count.
    private func vote(_ bubble: ChatBubble, _ choice: [String]) {
        guard let route else { return }
        Task { @MainActor in
            do {
                try await app.voteInChat(choice, on: bubble, route: route, name: entry.name)
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
        guard let route else { return }
        let thread = app.chatThread(entry)
        Task { @MainActor in
            do {
                try await app.reactInChat(emoji, to: bubble, route: route, thread: thread, name: entry.name)
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

    /// ↑ in the empty field: your newest message with text goes into the field to change it.
    private func editLastMessage() -> Bool {
        guard let mine = bubbles.last(where: { $0.fromMe && !$0.local && !$0.text.isEmpty && $0.poll == nil && $0.call == nil }) else { return false }
        edit(mine)
        return true
    }

    /// The changed text goes to your message; when it fails the text stays in the field to try again.
    private func sendEdit(_ bubble: ChatBubble, route: ChatRoute) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != bubble.text else {
            withAnimation(NookTheme.reveal) { editing = nil }
            reply = ""
            return
        }
        notice = nil
        reply = ""
        withAnimation(NookTheme.reveal) { editing = nil }
        enqueue {
            do {
                try await app.editInChat(bubble, text: text, route: route, name: entry.name)
            } catch {
                if reply.isEmpty { reply = text }
                notice = error.localizedDescription
            }
        }
    }

    /// Your message goes for everyone in the chat, once you confirmed it.
    private func delete(_ bubble: ChatBubble) {
        guard let route else { return }
        Task { @MainActor in
            do {
                try await app.deleteInChat(bubble, route: route, name: entry.name)
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

    /// A chat with no messages here yet (one its app lists, still loading): says so instead of an empty space.
    private var emptyChat: some View {
        VStack(spacing: NookTheme.Spacing.sm) {
            ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 56)
            Text(entry.name)
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
            Text(tr("chats.detail.empty", appName))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, NookTheme.Spacing.xxxl)
    }

    /// Who and where on top: the picture, the name, and under it the app, the group's people, someone typing, and where
    /// the chat stands; opening the app and the rest of the actions on the right. The same for every app.
    private var header: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if let onBack { PanelBackButton(action: onBack) }
            ChatsAvatar(name: entry.name, app: entry.app, photo: photo, size: 36)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(entry.name)
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                HStack(spacing: NookTheme.Spacing.xs) {
                    if let typingLine = typing.line(entry.id) {
                        // Someone typing says so where the chat's details are, as a chat app's header does.
                        Text(typingLine)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.mint)
                            .lineLimit(1)
                            .transition(.opacity)
                    } else {
                        headerDetails
                    }
                }
                .animation(NookTheme.reveal, value: typing.line(entry.id))
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            // Opening the app stays in sight; the rest waits in the "…" menu.
            ToolbarIconButton("arrow.up.forward.app", tr("chats.openApp", appName)) { app.openChatApp(entry.app) }
            moreMenu
        }
    }

    /// The app (and whether Nook reads it or only saw its notifications), the group's people, and where it stands.
    @ViewBuilder
    private var headerDetails: some View {
        // A chat a bridge reads is the app's own; any other is what its notifications showed.
        Text(route == nil && !capture.bridged.contains(entry.app) ? tr("chats.fromNotifications", appName) : appLine)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
        // A group whose app lists its people: how many, and a click lists them.
        if let members = entry.members, !members.isEmpty {
            headerDot
            ChatMembersButton(members: members)
        }
        // Read but not new: where it stands, small, instead of a strip above the answer field.
        if !entry.read.isUnread && !entry.lastIsMine && !bubbles.isEmpty {
            headerDot
            ChatReadStatus(state: entry.read, appName: appName, handoff: app.chatReadHandoff(entry),
                           markReadInApp: { app.markChatReadInApp(entry) })
        }
    }

    private var headerDot: some View {
        Text("·")
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .accessibilityHidden(true)
    }

    /// Read or unread by hand, the same for every chat (as its row's menu), what its app lets Nook do there, and removing
    /// a chat collected from notifications.
    private var moreMenu: some View {
        Menu {
            if entry.read.isUnread {
                Button(tr("chats.markReadInNook")) { app.markChatReadInNook(entry) }
            }
            if entry.read != .read {
                Button(tr("chats.markReadInApp", appName)) { app.markChatReadInApp(entry) }
            }
            if !entry.read.isUnread {
                Button(tr("chats.markUnread"), action: onMarkUnread)
            }
            let abilities = self.abilities
            if let route, abilities.pin || abilities.mute || abilities.archive {
                Divider()
                if abilities.pin {
                    Button(tr(abilities.pinned ? "chats.unpinInApp" : "chats.pinInApp", appName)) {
                        change { try await app.setChatPinned(!abilities.pinned, route: route, name: entry.name) }
                    }
                }
                if abilities.mute {
                    Button(tr(abilities.muted ? "chats.unmuteInApp" : "chats.muteInApp", appName)) {
                        change { try await app.setChatMuted(!abilities.muted, route: route, name: entry.name) }
                    }
                }
                if abilities.archive {
                    Button(tr("chats.archiveInApp", appName)) {
                        change {
                            try await app.archiveChat(route: route, thread: app.chatThread(entry), name: entry.name)
                            onClose()
                        }
                    }
                }
            }
            if let thread = app.chatThread(entry) {
                Divider()
                Button(tr("chats.remove"), role: .destructive) { removing = thread }
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
        .confirmDelete($removing, question: { _ in tr("confirm.deleteChat", entry.name) },
                       detail: tr("confirm.deleteChat.detail"), confirmTitle: tr("chats.remove")) { capture.remove($0) }
    }

    /// One field for every chat: what you type goes to a chat Nook can write in (WhatsApp, Telegram, an app the chat helper links),
    /// or is copied for the app of any other chat; "@nook …" lets Nook write the message first, into this field, for
    /// you to read before it goes anywhere. Where Nook can write, the field takes more than text, as the app's own does:
    /// photos, videos, GIFs, stickers, files, a voice message, a poll, a place, a contact, an emoji.
    @ViewBuilder
    private var footer: some View {
        let route = self.route
        let sends = app.chatSends(route)
        // Something new and its steps sit in the tray above the box, as an agent's queued messages do; once read in
        // Nook, where it stands moves to the header, so the tray is gone.
        let field = ChatReplyField(
            text: $reply, notice: $notice, focus: $replyFocused,
            placeholder: route == nil ? tr("chats.reply.copyPrompt", entry.name) : tr("chats.reply.prompt", entry.name),
            sendSymbol: route == nil ? "doc.on.doc" : "arrow.up",
            sendLabel: route == nil ? tr("chats.reply.copy", appName) : tr("chats.send"),
            readyNotice: route == nil ? tr("chats.draft.readyCopy", appName) : tr("chats.draft.ready"),
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
                if let editing, let route {
                    sendEdit(editing, route: route)
                } else if let route {
                    send(via: route)
                } else {
                    copyForApp()
                }
            })
            .editsLastMessage(abilities.edit && route != nil ? editLastMessage : nil)
            .tray(entry.read.isUnread
                ? AnyView(ChatReadLine(state: entry.read, appName: appName, handoff: app.chatReadHandoff(entry),
                                       markReadInNook: { app.markChatReadInNook(entry) },
                                       markReadInApp: { app.markChatReadInApp(entry) }))
                : limitsLine(route: route))
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
    /// leaves the field at once and shows in the chat when the app has it, with no panel in between; when it fails the
    /// text is back in the field, the files that did not go wait again, and the quote stays. Text alone is in the chat
    /// the moment you send it (`ChatOutbox`), with a clock until its app took it.
    private func send(via route: ChatRoute) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = composer.files
        guard !text.isEmpty || !files.isEmpty else { return }
        notice = nil
        reply = ""
        let quoted = replyingTo?.id
        withAnimation(NookTheme.reveal) { replyingTo = nil }
        for file in files { composer.sent(.file(file)) }
        replyFocused = true
        let chat = entry.id
        let shown = files.isEmpty
            ? outbox.add(text, quote: quoted.flatMap { id in bubbles.first { $0.id == id } }?.quote(contact: entry.name),
                         chat: chat, shown: bubbles)
            : nil
        enqueue {
            // The text still to go: once it went as a caption, a failure later does not put it back to go twice.
            var caption = text
            var waiting = files
            do {
                var answers = quoted
                for var file in files {
                    let captioned = !caption.isEmpty && [ChatMedia.Kind.photo, .video, .gif, .file].contains(file.kind)
                    if captioned { file.caption = caption }
                    try await app.sendChatItem(.file(file), route: route, chat: entry.name, replyTo: answers)
                    waiting.removeFirst()
                    answers = nil
                    if captioned { caption = "" }
                }
                // Answering reads the chat, once for the whole send.
                if !caption.isEmpty {
                    try await app.sendChatText(caption, route: route, chat: entry.name, replyTo: answers, thread: entry.id)
                } else {
                    await app.answeredInChat(route, name: entry.name, thread: entry.id)
                }
                if let shown { outbox.sent(shown, chat: chat) }
            } catch {
                if let shown { outbox.failed(shown, chat: chat) }
                if !caption.isEmpty, reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reply = caption }
                composer.restore(waiting)
                if let quoted, replyingTo == nil { replyingTo = bubbles.first { $0.id == quoted } }
                notice = tr("whatsapp.card.notSent", error.localizedDescription)
            }
        }
    }

    /// One thing sent at once, after your own click: a poll, a place, a contact, a sticker, a voice message. It goes
    /// straight away, as text does.
    private func sendItem(_ item: ChatOutgoing) {
        guard let route = self.route else { return }
        notice = nil
        let quoted = replyingTo?.id
        let poll = composer.poll
        composer.sent(item)
        if quoted != nil { withAnimation(NookTheme.reveal) { replyingTo = nil } }
        enqueue {
            do {
                try await app.sendChatItem(item, route: route, chat: entry.name, replyTo: quoted, thread: entry.id)
            } catch {
                // A poll you wrote is not lost: its form comes back as it was.
                if case .poll = item { composer.poll = poll; composer.panel = .poll }
                notice = tr("whatsapp.card.notSent", error.localizedDescription)
            }
        }
    }

    /// Runs a send after the ones still going, so the chat gets your messages in the order you sent them.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let before = sending
        sending = Task { @MainActor in
            await before?.value
            await work()
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

    /// A file opens in Quick Look, the same for every app (`AppModel.openChatFile`): from this Mac when Nook has it,
    /// else fetched or opened in its app; the chat says so while it is fetched, and why when it cannot.
    private func open(_ bubble: ChatBubble) {
        if bubble.file == nil, let name = bubble.attachment { notice = tr("whatsapp.file.opening", name) }
        Task { @MainActor in
            do {
                try await app.openChatFile(bubble, in: entry)
                if bubble.file == nil, bubble.attachment != nil { notice = nil }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Whether the chat may have older messages to scroll back to, as its app keeps them.
    private var canLoadOlder: Bool { app.canLoadOlderChat(entry) }

    private func loadOlder() async -> Bool { await app.loadOlderChat(entry) }
}
