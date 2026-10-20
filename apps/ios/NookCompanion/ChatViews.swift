import SwiftUI

/// Where the Chat tab navigates: a chat that exists, or a new one (the id only makes each "new chat" its own screen).
enum ChatRoute: Hashable {
    case new(UUID)
    case open(String)
}

// MARK: The list

/// Nook's own chats on the Mac: the same conversations as in the notch, newest first.
struct ChatListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [ChatRoute]

    var body: some View {
        List {
            if !client.can(CompanionFeature.chat) {
                Label("Update Nook on your Mac to chat with Nook from your phone.", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
            } else {
                if !client.brainReady {
                    Label("Nook has no brain set up on your Mac yet: choose one in Nook › Settings.", systemImage: "brain")
                        .font(.footnote).foregroundStyle(Palette.amber)
                }
                ForEach(client.conversations) { conversation in
                    NavigationLink(value: ChatRoute.open(conversation.id)) { ChatRow(conversation: conversation) }
                }
                if client.conversations.isEmpty, client.phase == .connected {
                    Text("No chats yet. Start one with the pencil.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(for: ChatRoute.self) { route in
            switch route {
            case .new: ChatView(conversationID: nil)
            case .open(let id): ChatView(conversationID: id)
            }
        }
        .refreshable { await client.loadChats() }
        .toolbar {
            if client.can(CompanionFeature.chat) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { path.append(.new(UUID())) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                }
            }
        }
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title).font(.headline).lineLimit(1)
                if !conversation.preview.isEmpty {
                    Text(conversation.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(Date(timeIntervalSince1970: conversation.updated), format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
                if conversation.busy {
                    ProgressView().controlSize(.small)
                } else if conversation.waiting {
                    Circle().fill(Palette.amber).frame(width: 9, height: 9)
                        .accessibilityLabel("Waits for you on your Mac")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: One chat

struct ChatView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var id: String?
    @State private var text = ""
    @State private var sending = false

    init(conversationID: String?) {
        _id = State(initialValue: conversationID)
    }

    private var lines: [ChatLine] { id.flatMap { client.chatLines[$0] } ?? [] }
    private var busy: Bool { sending || lines.last?.streaming == true }
    private var title: String {
        id.flatMap { id in client.conversations.first { $0.id == id }?.title } ?? String(localized: "New chat")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty, !sending {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Palette.iris)
                            Text("Ask Nook anything: your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    ForEach(lines) { ChatLineView(line: $0) }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding()
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

struct ChatLineView: View {
    let line: ChatLine

    var body: some View {
        if line.fromNook {
            VStack(alignment: .leading, spacing: 6) {
                if line.text.isEmpty, line.streaming {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(line.status.isEmpty ? String(localized: "Thinking…") : line.status)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                } else if !line.text.isEmpty {
                    MessageBubble(text: line.text, mine: false, failed: line.failed)
                }
                if line.onMac {
                    Label("Nook made a plan, draft or chart: see it on your Mac.", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(Palette.amber)
                }
            }
        } else {
            MessageBubble(text: line.text, mine: true)
        }
    }
}

// MARK: Shared pieces

/// A message: yours on the right, the agent's or Nook's on the left, with inline Markdown.
struct MessageBubble: View {
    let text: String
    let mine: Bool
    var failed = false

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Markdown.text(text)
                .font(.body)
                .foregroundStyle(failed ? Palette.coral : .primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? Palette.iris.opacity(0.22) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 40) }
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if busy, trimmed.isEmpty, let onStop {
                Button(action: onStop) { Image(systemName: "stop.circle.fill").font(.title) }
                    .foregroundStyle(Palette.coral)
                    .accessibilityLabel("Stop")
            } else {
                Button {
                    let message = trimmed
                    text = ""
                    onSend(message)
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(trimmed.isEmpty)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
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
