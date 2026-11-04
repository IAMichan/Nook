import SwiftUI

/// Where the Chat tab navigates: a chat that exists, or a new one with an optional first question (the id only makes
/// each "new chat" its own screen).
enum ChatRoute: Hashable {
    case new(UUID, String)
    case open(String)
}

/// A few first questions, so an empty chat is never a blank page.
enum ChatSuggestions {
    static var all: [String] {
        [String(localized: "What’s on my calendar today?"),
         String(localized: "Summarize my unread mail."),
         String(localized: "What did my agents do today?")]
    }
}

// MARK: The list

/// The Nook tab, as on the Mac: Nook himself with the box to ask him something at the bottom, and his recent chats (the
/// same conversations as in the notch) above it. Asking starts a new chat.
struct ChatListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [ChatRoute]
    @State private var text = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelHeader()
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ConnectionLine()
                    if !client.can(CompanionFeature.chat) {
                        EmptyState(symbol: "arrow.down.circle", title: "Update Nook on your Mac",
                                   message: "Update Nook on your Mac to chat with Nook from your phone.") {}
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
                            AskNook { ask($0) }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                if !client.conversations.isEmpty {
                    SectionHeader(title: "Recent")
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.bottom, Theme.Spacing.xs)
                    VStack(spacing: Theme.Spacing.xxs) {
                        ForEach(client.conversations) { conversation in
                            NavigationLink(value: ChatRoute.open(conversation.id)) { ChatRow(conversation: conversation) }
                                .buttonStyle(RowPress())
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md)
                }
            }
            .padding(.bottom, Theme.Spacing.xxl)
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
        .refreshable { await client.loadChats() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: ChatRoute.self) { route in
            switch route {
            case .new(_, let prompt): ChatView(conversationID: nil, prompt: prompt)
            case .open(let id): ChatView(conversationID: id)
            }
        }
        .screen()
        .task {
            while !Task.isCancelled {
                await client.loadChats()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// A new chat that opens with this question.
    private func ask(_ question: String) {
        guard !question.isEmpty else { return }
        path.append(.new(UUID(), question))
    }
}

/// A conversation with Nook, as a row of the Mac's list: its title with when on the right, and how it ended under it.
struct ChatRow: View {
    let conversation: ChatDigest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(conversation.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(1)
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
                    PulseDot(color: Theme.accent, size: 6)
                    Text("Writing…")
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

/// An empty chat, as the Mac's empty Nook tab: Nook, one line that says what he can do, and the starters two per row.
private struct AskNook: View {
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                NookMark(size: 44).padding(.bottom, Theme.Spacing.md)
                Text("Ask Nook anything").font(Theme.TextStyle.display).foregroundStyle(Theme.text)
                Text("Your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.")
                    .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
            }
            SuggestionGrid(suggestions: ChatSuggestions.all, ask: pick)
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
    private var title: String {
        id.flatMap { id in client.conversations.first { $0.id == id }?.title } ?? String(localized: "New chat")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    if lines.isEmpty, !sending, waiting.isEmpty {
                        AskNook { send($0) }
                    }
                    ForEach(lines) { ChatLineView(line: $0) }
                    if sending, lines.last?.fromNook != true { ThinkingLine(status: "") }
                    // What waits for the Mac, dimmed, until it takes it.
                    ForEach(waiting) { entry in
                        TranscriptUserMessage(text: entry.request.text ?? "", pending: true)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.text) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerDock {
                SessionComposer(text: $text, prompt: "Ask Nook", canSend: client.brainReady, busy: busy, onStop: stop) {
                    let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    text = ""
                    send(question)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { SheetTitle(title: title, subtitle: "Nook") } }
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
        // Quick while Nook writes, slow while it waits for you; a new chat starts the loop once it has an id.
        .task(id: id) {
            guard let id else { return }
            while !Task.isCancelled {
                await client.loadChat(id)
                let writing = client.chatLines[id]?.last?.streaming == true
                try? await Task.sleep(for: .seconds(writing ? 1.5 : 6))
            }
        }
    }

    private static let bottom = "bottom"

    private func send(_ question: String) {
        sending = true
        Haptics.tap()
        Task {
            switch await client.ask(question, in: id) {
            case .asked(let created):
                id = created
            case .waiting(let request):
                // Kept on the phone until the Mac answers; a new chat gets its id once the Mac took the question.
                if id == nil { waitingFor = request }
            case .refused:
                // Not sent: keep the text so nothing is lost.
                text = question
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
                            Image(systemName: "laptopcomputer").foregroundStyle(Theme.amber)
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
