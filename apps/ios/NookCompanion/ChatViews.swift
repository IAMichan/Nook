import SwiftUI
import UIKit

/// Where the Chat tab navigates: a chat that exists, or a new one with an optional first question (the id only makes
/// each "new chat" its own screen), and the archive of conversations (`CompanionFeature.nookChats`).
enum ChatRoute: Hashable {
    case new(UUID, String)
    case open(String)
    case archive
}

/// The screen a chat route opens: pushed on the phone, beside the list on the iPad (`CompanionSplitView`).
struct ChatDestination: View {
    let route: ChatRoute

    var body: some View {
        switch route {
        case .new(_, let prompt): ChatView(conversationID: nil, prompt: prompt)
        case .open(let id): ChatView(conversationID: id)
        case .archive: NookArchiveView()
        }
    }
}

/// A few first questions, so an empty chat is never a blank page: the Mac's own starters (`HomeDigest.suggestions`),
/// built from your day, or these from a Mac that does not send them.
enum ChatSuggestions {
    static var all: [String] {
        [String(localized: "What’s on my calendar today?"),
         String(localized: "Summarize my unread mail."),
         String(localized: "What did my agents do today?")]
    }

    static func starters(_ home: HomeDigest?) -> [String] {
        guard let suggestions = home?.suggestions, !suggestions.isEmpty else { return all }
        return Array(suggestions.prefix(4))
    }
}

// MARK: The list

/// The Nook tab, as on the Mac: the home (the greeting, For you, At a glance, Start with) with the box to ask Nook
/// something at the bottom, and his conversations (the same as in the notch) under it, as the Mac's list orders them:
/// what asks for you on top, the pinned ones, then by age, with a search and the archive. Asking starts a new chat.
struct ChatListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [ChatRoute]
    @State private var text = ""
    @State private var query = ""
    @State private var menu = NookChatMenuState()

    private var listsLikeTheMac: Bool { client.can(CompanionFeature.nookChats) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelHeader()
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ConnectionLine()
                    // What needs you across agents and chats, at a glance; an empty first visit leaves the stage to Nook.
                    if showsOverview { AttentionOverview() }
                    if let home = client.home, client.allows(.read) {
                        HomeGlanceRow(home: home, ask: ask)
                            .padding(.top, Theme.Spacing.sm)
                    }
                    if !client.can(CompanionFeature.chat) {
                        WSEmptyState(symbol: "arrow.down.circle", title: String(localized: "Update Nook on your Mac"),
                                   message: String(localized: "Update Nook on your Mac to chat with Nook from your phone."))
                    } else {
                        if !client.brainReady {
                            Banner(text: String(localized: "Nook has no brain set up on your Mac yet: choose one in Nook › Settings."), symbol: "brain")
                        }
                        // New chats whose first question waits for the Mac.
                        ForEach(client.outbox.questions(in: nil)) { entry in
                            WaitingRow(symbol: "sparkles", title: entry.request.text ?? "",
                                       detail: String(localized: "New chat · waiting for your Mac")) { client.discardWaiting(entry.id) }
                        }
                        if client.conversations.isEmpty {
                            AskNook(suggestions: ChatSuggestions.starters(client.home)) { ask($0) }
                        } else if client.home != nil {
                            HomeStarters(suggestions: ChatSuggestions.starters(client.home), ask: ask)
                                .padding(.top, Theme.Spacing.sm)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                if !client.conversations.isEmpty || client.nookArchived > 0 {
                    if listsLikeTheMac {
                        NookConversationList(query: $query, menu: $menu)
                    } else {
                        SectionHeader(title: String(localized: "Recent"))
                            .padding(.horizontal, Theme.Spacing.xl)
                            .padding(.bottom, Theme.Spacing.xs)
                        VStack(spacing: Theme.Spacing.xxs) {
                            ForEach(client.conversations) { conversation in
                                OpenLink(value: ChatRoute.open(conversation.id)) { ChatRow(conversation: conversation) }
                                    .buttonStyle(RowPress())
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
            .animation(Theme.reveal, value: client.conversations)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if client.can(CompanionFeature.chat) {
                ComposerDock {
                    SessionComposer(text: $text, prompt: "Ask Nook", canSend: client.brainReady) {
                        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        ask(question)
                    }
                }
            }
        }
        .nookChatMenu($menu)
        .refreshable {
            await client.loadChats()
            await client.loadHome()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: ChatRoute.self) { route in ChatDestination(route: route) }
        .screen()
        .task {
            // A Mac that sends Nook's conversations by itself (`liveChats`) needs one look; otherwise every few seconds.
            while !Task.isCancelled {
                await client.loadChats()
                repeat { try? await Task.sleep(for: .seconds(5)) } while !Task.isCancelled && client.chatsAreLive
            }
        }
        .task {
            // The home changes slowly (the next meeting, the limits, what plays): a look every minute while it shows.
            while !Task.isCancelled {
                await client.loadHome()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// The overview shows once there is something to tell: sessions, chats, the Mac's home, or earlier conversations.
    private var showsOverview: Bool {
        !client.sessions.isEmpty || !client.conversations.isEmpty || (client.allows(.chats) && !client.inbox.isEmpty)
            || client.home != nil
    }

    /// A new chat that opens with this question.
    private func ask(_ question: String) {
        guard !question.isEmpty else { return }
        path.append(.new(UUID(), question))
    }
}

/// Nook's conversations as the Mac's Nook tab lists them (`NookList`): a search, what asks something of you on a card
/// of its own, the pinned ones, then Today, Yesterday, Previous 7 days and Older, and the archive at the foot. A long
/// press on a row offers what its menu on the Mac does.
private struct NookConversationList: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var query: String
    @Binding var menu: NookChatMenuState

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        // The Mac sends its whole open list, so a search there finds what a search here finds: the same words matched.
        let shown = client.conversations.filter { NookChatSections.matches($0, query: query) }
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let sections = NookChatSections.sections(shown, searching: searching, now: context.date)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                SectionHeader(title: String(localized: "Conversations"))
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.xl)
                if client.conversations.count > 4 || searching {
                    NookSearchField(prompt: "Search conversations", text: $query)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.bottom, Theme.Spacing.sm)
                }
                if searching, shown.isEmpty {
                    ListEmptyNote(String(localized: "No matches"))
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.md)
                }
                if !sections.attention.isEmpty {
                    // What asks something of you, on a card on top, so it never hides between the read ones.
                    rows(sections.attention)
                        .padding(.vertical, Theme.Spacing.xs)
                        .cardBackground(Theme.surface, stroke: Theme.line2, radius: Theme.Radius.panel)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.bottom, Theme.Spacing.sm)
                }
                ForEach(sections.groups) { group in
                    SectionHeader(title: Self.title(group.group))
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.top, Theme.Spacing.md)
                    rows(group.chats)
                        .padding(.horizontal, Theme.Spacing.md)
                }
                if client.nookArchived > 0 {
                    OpenLink(value: ChatRoute.archive) {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(icon: "archivebox").font(Theme.font(13, .medium)).foregroundStyle(Theme.textSecondary)
                            Text("Archived").font(Theme.TextStyle.strong).foregroundStyle(Theme.textStrong)
                            Text(client.nookArchived, format: .number)
                                .font(Theme.TextStyle.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Image(icon: "chevron.right").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowPress())
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.lg)
                }
            }
        }
    }

    private func rows(_ chats: [ChatDigest]) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            ForEach(chats) { conversation in
                OpenLink(value: ChatRoute.open(conversation.id)) { ChatRow(conversation: conversation) }
                    .buttonStyle(RowPress())
                    .contextMenu { NookChatMenuItems(chat: conversation, menu: $menu) }
            }
        }
    }

    static func title(_ group: NookChatSections.Group) -> String {
        switch group {
        case .pinned: return String(localized: "Pinned")
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .previousWeek: return String(localized: "Previous 7 days")
        case .older: return String(localized: "Older")
        }
    }
}

/// The archived conversations, as the Mac's archive shelf: searchable, each with its menu (Unarchive, Delete…).
struct NookArchiveView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var query = ""
    @State private var menu = NookChatMenuState()

    private var found: [ChatDigest] { client.nookFound ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                NookSearchField(prompt: "Search the archive", text: $query)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.md)
                if client.nookFound != nil, found.isEmpty {
                    ListEmptyNote(query.isEmpty ? String(localized: "The archive is empty") : String(localized: "No matches"))
                        .padding(.horizontal, Theme.Spacing.xl)
                }
                ForEach(found) { conversation in
                    OpenLink(value: ChatRoute.open(conversation.id)) { ChatRow(conversation: conversation) }
                        .buttonStyle(RowPress())
                        .contextMenu { NookChatMenuItems(chat: conversation, menu: $menu) }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.lg)
            .readingColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { SheetTitle(title: String(localized: "Archived"), subtitle: "Nook") } }
        .nookChatMenu($menu)
        .screen()
        .refreshable { await client.searchNookChats(query, archive: true) }
        .task(id: query) {
            // A pause after the last key, so a search goes once per word instead of once per letter.
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await client.searchNookChats(query, archive: true)
        }
        // The list changed (something archived or brought back): the archive is read again.
        .onChange(of: client.nookArchived) { _, _ in Task { await client.searchNookChats(query, archive: true) } }
        .onDisappear { client.nookFound = nil }
    }
}

/// A conversation with Nook, as a row of the Mac's list: its title with when on the right, and how it ended under it;
/// a dot while an answer waits unread, a pin when it is pinned, and the questions that wait in line.
struct ChatRow: View {
    let conversation: ChatDigest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                if conversation.unread == true, !conversation.busy, !conversation.waiting {
                    Circle().fill(Theme.iris).frame(width: 7, height: 7)
                        .accessibilityLabel("Unread")
                }
                Text(conversation.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                if conversation.pinned == true {
                    Image(icon: "pin.fill").font(Theme.font(9)).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: Theme.Spacing.md)
                if conversation.waiting {
                    StatusPill(attention: "input", short: true)
                } else {
                    Text(Date(timeIntervalSince1970: conversation.updated), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            if conversation.busy {
                HStack(spacing: Theme.Spacing.sm) {
                    PulseDot(color: Theme.blue, size: 6)
                    Text("Writing…")
                    if let queued = conversation.queued?.count, queued > 0 {
                        Text(verbatim: "·")
                        Text("\(queued) waiting")
                    }
                }
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
            } else if !conversation.preview.isEmpty {
                Text(conversation.preview).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(2)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md + Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: The conversation menu

/// What a conversation's menu is busy with: the new name being typed, and the delete that waits for a yes.
struct NookChatMenuState {
    var renaming: ChatDigest?
    var name = ""
    var deleting: ChatDigest?
    /// Set when a delete went through, so an open conversation can close.
    var deleted: String?
}

/// The Mac's conversation menu (`NookTab.conversationMenu`, the list's right-click), for a long press on a row and the
/// "…" in a conversation's header: rename, pin, mark unread, copy, archive and delete; retry in the conversation.
struct NookChatMenuItems: View {
    @EnvironmentObject private var client: CompanionClient
    let chat: ChatDigest
    @Binding var menu: NookChatMenuState
    /// In the conversation itself: Nook answers the last question again.
    var offersRetry = false

    var body: some View {
        Button {
            menu.name = chat.title
            menu.renaming = chat
        } label: { Label("Rename", systemImage: "pencil") }
        if chat.archived != true {
            Button { act(.init(kind: .pin, value: chat.pinned != true)) } label: {
                Label(chat.pinned == true ? "Unpin" : "Pin", systemImage: chat.pinned == true ? "pin.slash" : "pin")
            }
        }
        if chat.unread == true {
            Button { act(.init(kind: .markUnread, value: false)) } label: { Label("Mark as read", systemImage: "envelope.open") }
        } else {
            Button { act(.init(kind: .markUnread, value: true)) } label: { Label("Mark as unread", systemImage: "envelope.badge") }
        }
        Button {
            Task {
                // The messages the phone has; a conversation not opened yet is read first.
                if client.chatLines[chat.id] == nil { await client.loadChat(chat.id) }
                UIPasteboard.general.string = client.nookMarkdown(chat.id)
                Haptics.success()
            }
        } label: { Label("Copy conversation", systemImage: "doc.on.doc") }
        if offersRetry {
            Button { act(.init(kind: .retry)) } label: { Label("Retry last answer", systemImage: "arrow.clockwise") }
                .disabled(chat.busy)
        }
        Divider()
        if chat.archived == true {
            Button { act(.init(kind: .archive, value: false)) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                .disabled(chat.busy)
        } else {
            Button { act(.init(kind: .archive, value: true)) } label: { Label("Archive", systemImage: "archivebox") }
                .disabled(chat.busy)
        }
        Button(role: .destructive) { menu.deleting = chat } label: { Label("Delete", systemImage: "trash") }
            .disabled(chat.busy)
    }

    private func act(_ action: NookChatAction) {
        Haptics.tap()
        Task { await client.actOnNookChat(chat.id, action) }
    }
}

extension View {
    /// The new name and the question before a delete, for the conversation menu's `menu`.
    func nookChatMenu(_ menu: Binding<NookChatMenuState>) -> some View {
        modifier(NookChatMenuDialogs(menu: menu))
    }
}

private struct NookChatMenuDialogs: ViewModifier {
    @EnvironmentObject private var client: CompanionClient
    @Binding var menu: NookChatMenuState

    func body(content: Content) -> some View {
        content
            .alert("Rename conversation", isPresented: Binding(get: { menu.renaming != nil }, set: { if !$0 { menu.renaming = nil } }),
                   presenting: menu.renaming) { chat in
                TextField("Name", text: $menu.name)
                Button("Rename") {
                    let name = String(menu.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(NookChatAction.titleLimit))
                    guard !name.isEmpty, name != chat.title else { return }
                    Task { await client.actOnNookChat(chat.id, .init(kind: .rename, text: name)) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(menu.deleting.map { String(localized: "Delete “\($0.title)”?") } ?? "",
                                isPresented: Binding(get: { menu.deleting != nil }, set: { if !$0 { menu.deleting = nil } }),
                                titleVisibility: .visible, presenting: menu.deleting) { chat in
                Button("Delete", role: .destructive) {
                    Task {
                        if await client.actOnNookChat(chat.id, .init(kind: .delete)) {
                            Haptics.success()
                            menu.deleted = chat.id
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The conversation is gone from Nook on your Mac too. This cannot be undone.")
            }
    }
}

/// An empty chat, as the Mac's empty Nook tab: Nook, one line that says what he can do, and the starters two per row.
private struct AskNook: View {
    var suggestions = ChatSuggestions.all
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                NookMark(size: 44)
                    .background(NookAura(size: 150))
                    .padding(.bottom, Theme.Spacing.md)
                Text("Ask Nook anything").font(Theme.TextStyle.display).foregroundStyle(Theme.paper)
                Text("Your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.")
                    .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
            }
            SuggestionGrid(suggestions: suggestions, ask: pick)
        }
        .padding(.top, Theme.Spacing.xxl)
    }
}

// MARK: One chat

struct ChatView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var id: String?
    @State private var text = ""
    @State private var sending = false
    /// A suggestion picked on the list, sent once when the screen opens.
    private let prompt: String
    @State private var promptSent = false
    /// The question that started this chat waits in the outbox: its request id, until the Mac took it.
    @State private var waitingFor: String?
    /// This screen's own watch of the conversation (`CompanionClient.watchConversation`).
    @State private var watchOwner = UUID()
    /// Pictures that go with the next question (`CompanionFeature.nookChats`).
    @State private var images: [CompanionImage] = []
    @State private var menu = NookChatMenuState()
    @Environment(\.dismiss) private var dismiss

    init(conversationID: String?, prompt: String = "") {
        _id = State(initialValue: conversationID)
        self.prompt = prompt
    }

    private var lines: [ChatLine] { id.flatMap { client.chatLines[$0] } ?? [] }
    private var busy: Bool { sending || lines.last?.streaming == true }
    /// Questions of this chat that wait in the outbox for the Mac: in it, or (a new chat) the one asked here.
    private var waiting: [CompanionOutbox.Entry] {
        guard let id else { return client.outbox.entries.filter { $0.id == waitingFor } }
        return client.outbox.questions(in: id)
    }
    /// Changes when something new comes in at the end: a line, Nook's answer streaming in, a question waiting.
    private var followKey: [String] {
        [lines.last?.id ?? "", String(lines.last?.text.count ?? 0), String(lines.count), String(waiting.count), sending ? "1" : "0"]
    }
    private var title: String {
        id.flatMap { client.nookDigest($0)?.title } ?? String(localized: "New chat")
    }
    private var digest: ChatDigest? { id.flatMap { client.nookDigest($0) } }
    /// The Mac does what its Nook tab does: questions wait in line while Nook answers, pictures go with them.
    private var likeTheMac: Bool { client.can(CompanionFeature.nookChats) }

    var body: some View {
        ConversationScroll(followKey: followKey) { _ in
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                if lines.isEmpty, !sending, waiting.isEmpty {
                    if id != nil, client.isOffline {
                        // An earlier chat the phone did not keep: it opens once the Mac answers.
                        OfflineNote(text: String(localized: "This chat is not kept on this iPhone yet. It opens once your Mac is connected."))
                            .appearsAfterDelay()
                    } else {
                        AskNook { send($0) }
                    }
                }
                ForEach(lines) { ChatLineView(line: $0) }
                if sending, lines.last?.fromNook != true { ThinkingLine(status: "") }
                // What waits for the Mac, dimmed, until it takes it.
                ForEach(waiting) { entry in
                    TranscriptUserMessage(text: entry.request.text ?? "", pending: true)
                }
                // Questions that wait in line on the Mac for the answer Nook is writing, as its composer shows them.
                if let queued = digest?.queued, !queued.isEmpty {
                    VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                        ForEach(Array(queued.enumerated()), id: \.offset) { _, question in
                            TranscriptUserMessage(text: question, pending: true)
                        }
                        Label("Waits for this answer", systemImage: "clock")
                            .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .readingColumn()
        } floating: {
            EmptyView()
        } dock: { scroll in
            ComposerDock {
                if likeTheMac { ImageTray(images: $images) }
                SessionComposer(text: $text, prompt: "Ask Nook", canSend: client.brainReady, sending: sending && !likeTheMac,
                                allowsEmpty: !images.isEmpty, busy: busy, onStop: stop, onSend: {
                    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    text = ""
                    scroll.scrollToEnd()
                    send(question)
                }) {
                    if likeTheMac { AttachPictureButton(images: $images) }
                }
            }
            .readingColumn()
        }
        // Nook's chat takes words only: a dropped link or text lands in the box.
        .composerDrop(text: $text)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { SheetTitle(title: title, subtitle: "Nook") }
            if likeTheMac, let digest {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NookChatMenuItems(chat: digest, menu: $menu, offersRetry: lines.contains { !$0.fromNook })
                    } label: {
                        Image(icon: "ellipsis").font(Theme.font(15, .semibold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More actions")
                }
            }
        }
        .nookChatMenu($menu)
        // Deleted from its own menu: the conversation is gone, so is its screen.
        .onChange(of: menu.deleted) { _, deleted in if deleted != nil, deleted == id { dismiss() } }
        .screen()
        .onAppear {
            guard !promptSent, !prompt.isEmpty else { return }
            promptSent = true
            send(prompt)
        }
        // The question that waited went: this screen becomes that chat.
        .onChange(of: waitingFor.flatMap { client.askedConversations[$0] }) { _, created in
            guard let created else { return }
            id = created
            waitingFor = nil
        }
        // Live from a Mac that sends the open conversation by itself (`liveConversation`): Nook's words show as it writes
        // them. Otherwise, or while the connection is down, asked for: quick while Nook writes, slow while it waits for
        // you. A new chat starts the loop once it has an id.
        .task(id: id) {
            guard let id else { return }
            while !Task.isCancelled {
                if client.conversationIsLive, await client.watchConversation(id, owner: watchOwner) {
                    while !Task.isCancelled, client.conversationIsLive {
                        try? await Task.sleep(for: .seconds(2))
                        // An answer that went quiet on a shaky connection: asked again from where the phone is.
                        if client.conversationStalled(id) { break }
                    }
                    continue
                }
                await client.loadChat(id)
                let writing = client.chatLines[id]?.last?.streaming == true
                try? await Task.sleep(for: .seconds(writing ? 1.5 : 6))
            }
        }
        .onDisappear { if let id { Task { await client.unwatchConversation(id, owner: watchOwner) } } }
    }


    private func send(_ question: String) {
        let pictures = images
        guard !question.isEmpty || !pictures.isEmpty else { return }
        sending = true
        images = []
        Haptics.tap()
        Task {
            switch await client.ask(question, in: id, images: pictures) {
            case .asked(let created):
                id = created
            case .waiting(let request):
                // Kept on the phone until the Mac answers; a new chat gets its id once the Mac took the question.
                if id == nil { waitingFor = request }
            case .refused:
                // Not sent: keep the text and the pictures so nothing is lost.
                text = question
                images = pictures
            }
            sending = false
        }
    }

    private var stop: (() -> Void)? {
        guard let id else { return nil }
        return { Task { await client.stopChat(id) } }
    }
}

/// A message in a Nook chat, on the same `TranscriptUserMessage` and `TranscriptReply` as an agent's conversation, so
/// both read alike, as on the Mac.
struct ChatLineView: View {
    let line: ChatLine

    var body: some View {
        if line.fromNook {
            if line.text.isEmpty, line.streaming {
                ThinkingLine(status: line.status)
            } else {
                TranscriptReply(text: line.text, date: Date(timeIntervalSince1970: line.date), failed: line.failed,
                                footer: !line.streaming) {
                    if line.onMac {
                        Label {
                            Text("Nook made a plan, draft or chart: see it on your Mac.").foregroundStyle(Theme.textStrong)
                        } icon: {
                            Image(icon: "laptopcomputer").foregroundStyle(Theme.amber)
                        }
                        .font(Theme.TextStyle.detail)
                        .card(padding: Theme.Spacing.lg)
                    }
                }
            }
        } else {
            TranscriptUserMessage(text: line.text)
        }
    }
}

/// Nook at work: its mark, a live dot, and what it is doing.
private struct ThinkingLine: View {
    let status: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            NookMark(size: 22)
            Text(status.isEmpty ? String(localized: "Thinking…") : status)
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
            PulseDot(color: Theme.textSecondary, size: 5)
        }
    }
}
