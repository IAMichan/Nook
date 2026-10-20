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

/// Nook's own chats on the Mac: the same conversations as in the notch, newest first.
struct ChatListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [ChatRoute]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if !client.can(CompanionFeature.chat) {
                    EmptyState(symbol: "arrow.down.circle", title: "Update Nook on your Mac",
                               message: "Update Nook on your Mac to chat with Nook from your phone.") {}
                } else {
                    if !client.brainReady {
                        Banner(text: String(localized: "Nook has no brain set up on your Mac yet: choose one in Nook › Settings."), symbol: "brain")
                    }
                    if client.conversations.isEmpty {
                        if client.phase == .connected {
                            EmptyState(symbol: "sparkles", title: "Ask Nook anything",
                                       message: "Your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.") {
                                SuggestionList { path.append(.new(UUID(), $0)) }
                            }
                        }
                    } else {
                        ForEach(client.conversations) { conversation in
                            NavigationLink(value: ChatRoute.open(conversation.id)) { ChatRow(conversation: conversation) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
        }
        .refreshable { await client.loadChats() }
        .navigationTitle("Nook")
        .navigationDestination(for: ChatRoute.self) { route in
            switch route {
            case .new(_, let prompt): ChatView(conversationID: nil, prompt: prompt)
            case .open(let id): ChatView(conversationID: id)
            }
        }
        .toolbar {
            if client.can(CompanionFeature.chat) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.new(UUID(), "")) } label: {
                        Image(systemName: "square.and.pencil").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Theme.iris, in: Circle())
                    }
                    .accessibilityLabel("New chat")
                }
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
}

struct ChatRow: View {
    let conversation: ChatDigest

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            NookMark(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.sm)
                    Text(Date(timeIntervalSince1970: conversation.updated), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption2).foregroundStyle(Theme.textTertiary)
                }
                if conversation.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Writing…")
                    }
                    .font(.subheadline).foregroundStyle(Theme.iris)
                } else if !conversation.preview.isEmpty {
                    Text(conversation.preview).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                if conversation.waiting {
                    Label("Waits for you on your Mac", systemImage: "laptopcomputer")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.amber)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.amber.opacity(0.14), in: Capsule())
                }
            }
        }
        .card(padding: Theme.Spacing.md)
        .contentShape(Rectangle())
    }
}

/// The first questions as tappable rows.
private struct SuggestionList: View {
    let pick: (String) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(ChatSuggestions.all, id: \.self) { suggestion in
                Button { pick(suggestion) } label: {
                    HStack {
                        Text(suggestion).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(Theme.iris)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline))
                }
                .buttonStyle(.plain)
            }
        }
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

    init(conversationID: String?, prompt: String = "") {
        _id = State(initialValue: conversationID)
        self.prompt = prompt
    }

    private var lines: [ChatLine] { id.flatMap { client.chatLines[$0] } ?? [] }
    private var busy: Bool { sending || lines.last?.streaming == true }
    private var title: String {
        id.flatMap { id in client.conversations.first { $0.id == id }?.title } ?? String(localized: "New chat")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if lines.isEmpty, !sending {
                        EmptyState(symbol: "sparkles", title: "Ask Nook anything",
                                   message: "Your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.") {
                            SuggestionList { send($0) }
                        }
                    }
                    ForEach(lines) { ChatLineView(line: $0) }
                    if sending, lines.last?.fromNook != true { ThinkingLine(status: "") }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.text) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onChange(of: lines.count) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            ComposerBar(placeholder: "Ask Nook", text: $text, busy: busy, onStop: stop) { question in send(question) }
                .disabled(!client.brainReady)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .screen()
        .onAppear {
            guard !promptSent, !prompt.isEmpty else { return }
            promptSent = true
            send(prompt)
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
            if let created = await client.ask(question, in: id) {
                id = created
            } else {
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

/// A message in a Nook chat: yours in an iris bubble, Nook's as open text under its mark.
struct ChatLineView: View {
    let line: ChatLine

    var body: some View {
        if line.fromNook {
            if line.text.isEmpty, line.streaming {
                ThinkingLine(status: line.status)
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    NookMark(size: 26)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Markdown.text(line.text)
                            .font(.body)
                            .foregroundStyle(line.failed ? Theme.coral : Theme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if line.onMac {
                            Label("Nook made a plan, draft or chart: see it on your Mac.", systemImage: "laptopcomputer")
                                .font(.caption.weight(.medium)).foregroundStyle(Theme.amber)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.amber.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        } else {
            MessageBubble(text: line.text, mine: true)
        }
    }
}

/// Nook at work: its mark, a spinner, and what it is doing.
private struct ThinkingLine: View {
    let status: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            NookMark(size: 26)
            ProgressView().controlSize(.small)
            Text(status.isEmpty ? String(localized: "Thinking…") : status)
                .font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: Shared pieces

/// A message: yours as an iris bubble on the right, the agent's as a card on the left, with inline Markdown.
struct MessageBubble: View {
    let text: String
    let mine: Bool
    var failed = false

    var body: some View {
        if mine {
            HStack {
                Spacer(minLength: 48)
                Markdown.text(text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.iris, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            }
        } else {
            Markdown.text(text)
                .font(.body)
                .foregroundStyle(failed ? Theme.coral : Theme.text)
                .textSelection(.enabled)
                .card(padding: Theme.Spacing.md)
        }
    }
}

/// The field at the bottom of a conversation: send, or stop while an answer is being written and the field is empty.
struct ComposerBar: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var busy = false
    var onStop: (() -> Void)? = nil
    let onSend: (String) -> Void

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline))
            if busy, trimmed.isEmpty, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.body.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(Theme.coral, in: Circle())
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    let message = trimmed
                    text = ""
                    onSend(message)
                } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.bold))
                        .foregroundStyle(trimmed.isEmpty ? Theme.textTertiary : .white)
                        .frame(width: 42, height: 42)
                        .background(trimmed.isEmpty ? Theme.raised : Theme.iris, in: Circle())
                }
                .disabled(trimmed.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.sm)
        .background(Theme.canvas.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .animation(.spring(duration: 0.2), value: trimmed.isEmpty)
    }
}

enum Markdown {
    /// Inline Markdown (bold, code, links) with the line breaks kept; plain text when it does not parse.
    static func text(_ source: String) -> Text {
        if let styled = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(styled)
        }
        return Text(verbatim: source)
    }
}
