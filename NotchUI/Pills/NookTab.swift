import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Nook tab: home and chat in one. An empty conversation shows your day and suggestions; a running one the thread.
struct NookChatTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NookChatView(viewModel: viewModel, chat: app.chat)
    }
}

/// The chat, shared by the notch and the main window. `compact` is the notch version: a narrower list of Nooks.
struct NookChatView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var chat: NookChat
    var compact = true
    @EnvironmentObject private var app: AppModel
    @State private var question = ""
    @State private var dropTargeted = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !chat.history.isEmpty || !compact {
                NookList(chat: chat)
                    .frame(width: compact ? 168 : 220)
            }
            VStack(alignment: .leading, spacing: 0) {
                if chat.isEmpty {
                    emptyState
                } else {
                    thread
                }
                inputBar
                    .padding(.top, 10)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(NookTheme.iris, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .overlay(Text(tr("chat.dropFile")).font(NookTheme.font(13, .medium)).foregroundStyle(NookTheme.paper))
                    .allowsHitTesting(false)
            }
        }
        // Drop a file anywhere on the chat: Nook reads it and you ask about it (this replaces the old Shelf tab).
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { app.askAbout(url) }
            }
            return true
        }
        .onAppear {
            // Wait briefly for the panel to acquire keyboard focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { inputFocused = true }
        }
    }

    // MARK: Empty chat: your day and where to start

    private var emptyState: some View {
        let items = app.todayItems
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(items.isEmpty ? Greeting.quiet() : Greeting.line(count: items.count))
                    .font(NookTheme.font(20, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(tr("chat.emptySubtitle"))
                    .font(NookTheme.font(13))
                    .foregroundStyle(NookTheme.textSecondary)
            }

            if !items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(items.prefix(compact ? 3 : 6)) { item in
                        TodayRow(item: item) { open(item) }
                    }
                }
            }

            Spacer(minLength: 8)

            suggestions
        }
    }

    private func open(_ item: TodayItem) {
        switch item.target {
        case .card(let scene):
            viewModel.show(.card(DemoContent.card(for: scene)))
        case .agent(let id):
            viewModel.selectedAgentID = id
            if compact { viewModel.show(.panel(.agents)) } else { app.openWorkspace() }
        case .action(let run):
            run()
        case .none:
            break
        }
    }

    /// One-click prompt suggestions tailored to your current context (window, event, agents, time of day).
    private var suggestions: some View {
        SuggestionRow(questions: app.startSuggestions) { app.handleUserText($0) }
    }

    // MARK: Conversation

    private var thread: some View {
        ZStack(alignment: .topTrailing) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(chat.messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 2)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: scrollKey) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            if let title = chat.active?.title {
                // The current Nook conversation and option to start a new one.
                HStack(spacing: 6) {
                    Text(title)
                        .font(NookTheme.font(11.5, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                    NookIconButton(systemName: "square.and.pencil", label: tr("nooks.new"), size: 26) {
                        app.newChat()
                    }
                }
                .padding(.leading, 10)
                .background(Capsule().fill(NookTheme.notch))
                .offset(y: -6)
            }
        }
    }

    /// Updates as streamed responses arrive, keeping the chat scrolled to bottom.
    private var scrollKey: String {
        guard let last = chat.messages.last else { return "" }
        return "\(last.id)-\(last.text.count)-\(last.charts.count)-\(last.mails.count)-\(last.actions.count)-\(last.status)-\(last.retrieval.count)-\(last.references.count)"
    }

    // MARK: Input

    /// The same composer as the agents: the text on top, quiet choices underneath, a round send button on the right.
    private var inputBar: some View {
        SessionComposer(
            text: $question,
            prompt: chat.isEmpty ? tr("home.inputPrompt") : tr("chat.followupPrompt"),
            busy: chat.busy,
            onStop: { app.stopChat() },
            focus: $inputFocused,
            onSend: send
        ) {
            // Brain, allowed sources for this Nook, context payload, and optional file attachment.
            BrainChip()
            ScopeMenu(chat: chat)
            if let name = app.attachmentName {
                AttachmentChip(name: name) { app.clearAttachment() }
            }
            if !chat.busy, let last = chat.messages.last, last.role == .nook, last.isError || !last.notices.isEmpty {
                SmallGhostButton(title: tr("chat.retry")) { app.retryLast() }
            }
            NookIconButton(systemName: "paperclip", label: tr("chat.attach"), size: 26) { app.attachFile() }
                .help(tr("chat.attach"))
            NookIconButton(systemName: "mic", label: tr("button.talk"), size: 26) { viewModel.startListening() }
            ContextInspector(chat: chat)
        }
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        question = ""
        app.handleUserText(text)
        inputFocused = true
    }
}

// MARK: Single message

private struct ChatMessageView: View {
    let message: ChatMessage
    @EnvironmentObject private var app: AppModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: user
        case .nook: nook
        }
    }

    private var user: some View {
        HStack {
            Spacer(minLength: 80)
            Text(message.text)
                .font(NookTheme.font(14))
                .foregroundStyle(NookTheme.paper)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NookTheme.smoke))
        }
    }

    private var nook: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Where Nook looked and the outcome: searched, empty, or failed.
            RetrievalStrip(message: message)

            if message.isError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.text)
                        .font(NookTheme.font(13.5))
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 4) {
                        SmallGhostButton(title: tr("chat.retry")) { app.retryLast() }
                        let recovery = ChatRecoveryAction.forError(message.text, selection: app.settings.selection)
                        SmallGhostButton(title: app.recoveryTitle(recovery)) { app.performRecovery(recovery) }
                    }
                }
            } else if !message.text.isEmpty {
                MarkdownView(text: message.text)
            } else if message.streaming && message.charts.isEmpty && message.mails.isEmpty {
                TypingIndicator(status: message.status)
            }

            ForEach(message.charts) { chart in
                ChatChartView(chart: chart)
            }

            ForEach(message.mails) { mail in
                MailDraftView(
                    draft: mail,
                    onSend: { app.sendMail($0) },
                    onOpen: { app.openMail($0) }
                )
                .id(mail.id)
            }

            if !message.notices.isEmpty && !message.streaming {
                NoticeList(notices: message.notices)
            }

            if !message.references.isEmpty && !message.streaming {
                ReferenceList(references: message.references, cited: Citations.used(in: message.text))
            }

            if !message.actions.isEmpty {
                PlanReview(message: message)
            }

            // What Nook can do next: one click to execute.
            if !message.streaming && !message.offers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.offers, id: \.self) { offer in
                        Button { app.handleUserText(offer) } label: {
                            Text(offer)
                                .font(NookTheme.font(12, .medium))
                                .foregroundStyle(NookTheme.textSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Nook: \(offer)")
                    }
                }
            }

            if message.streaming && !message.text.isEmpty && !message.status.isEmpty {
                TypingIndicator(status: message.status)
            }

            if !message.streaming && !message.isError && !message.text.isEmpty {
                HStack(spacing: 2) {
                    SmallGhostButton(title: copied ? "Gekopieerd" : "Kopieer") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        copied = true
                    }
                }
                .opacity(hovering ? 1 : 0)
                .padding(.top, -6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Three gentle dots while Nook is thinking, along with its current activity.
private struct TypingIndicator: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(NookTheme.iris)
                            .frame(width: 6, height: 6)
                            .opacity(0.35 + 0.65 * abs(sin(t * 3 + Double(i) * 0.6)))
                    }
                }
            }
            if !status.isEmpty {
                Text(status)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityLabel(status.isEmpty ? "Nook denkt na" : status)
    }
}

// MARK: Your Nooks

/// All your Nooks listed: each conversation is a dedicated Nook working on a specific task. Busy, waiting for you, or done
/// is indicated by the dot. Start a new one at the top; right-click to delete.
private struct NookList: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @State private var showArchived = false
    @State private var renaming: UUID?
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NewNookButton { app.newChat() }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    let items = chat.list(query: "", showArchived: showArchived)
                    if items.isEmpty {
                        Text(tr("nooks.none"))
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                    }
                    ForEach(items) { conversation in
                        if renaming == conversation.id {
                            TextField("", text: $nameDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(NookTheme.font(12))
                                .onSubmit {
                                    chat.rename(conversation.id, to: nameDraft)
                                    renaming = nil
                                }
                                .onExitCommand { renaming = nil }
                        } else {
                            NookRow(conversation: conversation, selected: conversation.id == chat.activeID) {
                                app.openConversation(conversation.id)
                            }
                            .contextMenu {
                                Button(tr("nooks.rename")) {
                                    nameDraft = conversation.title
                                    renaming = conversation.id
                                }
                                if !conversation.archived {
                                    Button(tr(conversation.pinned ? "nooks.unpin" : "nooks.pin")) { chat.togglePin(conversation.id) }
                                }
                                Button(tr(conversation.archived ? "nooks.unarchive" : "nooks.archive")) {
                                    chat.setArchived(!conversation.archived, conversation.id)
                                }
                                Divider()
                                Button(tr("nooks.delete"), role: .destructive) { chat.delete(conversation.id) }
                            }
                        }
                    }
                }
            }

            if chat.hasArchived || showArchived {
                Button {
                    showArchived.toggle()
                } label: {
                    Label(tr(showArchived ? "nooks.hideArchive" : "nooks.showArchive"), systemImage: showArchived ? "tray.full" : "archivebox")
                        .font(NookTheme.font(11.5, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
        }
        .padding(.trailing, 12)
        .overlay(alignment: .trailing) { Rectangle().fill(NookTheme.line).frame(width: 1) }
    }
}

private struct NewNookButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                Text(tr("nooks.new"))
                    .font(NookTheme.font(12.5, .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? NookTheme.smoke : NookTheme.graphite))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut("n", modifiers: .command)
        .help(tr("nooks.newHelp"))
    }
}

private struct NookRow: View {
    let conversation: Conversation
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                StatusDot(status: conversation.status)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(NookTheme.font(12.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? NookTheme.paper : Color(hex: 0xC9C7D2))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? NookTheme.smoke : (hovering ? NookTheme.graphite : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(conversation.title), \(subtitle)")
    }

    private var subtitle: String {
        switch conversation.status {
        case .working: return tr("nooks.working")
        case .waiting: return tr("nooks.waiting")
        case .unread: return tr("nooks.doneAt", NookDates.ago(conversation.updated))
        case .idle: return conversation.preview.isEmpty ? NookDates.ago(conversation.updated) : conversation.preview
        }
    }
}

/// Busy (purple, breathing), waiting for you (amber), new response (mint), or idle (gray).
private struct StatusDot: View {
    let status: Conversation.Status

    var body: some View {
        switch status {
        case .working:
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Circle().fill(NookTheme.iris).frame(width: 7, height: 7)
                    .opacity(0.45 + 0.55 * abs(sin(t * 2.6)))
            }
            .frame(width: 7, height: 7)
        case .waiting:
            Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .unread:
            Circle().fill(NookTheme.mint).frame(width: 7, height: 7)
        case .idle:
            Circle().stroke(NookTheme.textTertiary, lineWidth: 1.2).frame(width: 7, height: 7)
        }
    }
}

// MARK: Starters

/// Suggested conversation starters as compact buttons.
private struct SuggestionRow: View {
    let questions: [String]
    let ask: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(questions, id: \.self) { question in
                Button { ask(question) } label: {
                    Text(question)
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(NookTheme.smoke))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct TodayRow: View {
    let item: TodayItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Circle().fill(item.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NookTheme.font(14.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                    Text(item.subtitle)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                Spacer()
                if !item.action.isEmpty {
                    Text(item.action)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(Color(hex: 0xC9C7D2))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(hovering ? NookTheme.field : Color.clear)
            .overlay(alignment: .top) { Rectangle().fill(NookTheme.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
