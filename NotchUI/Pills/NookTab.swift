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
    @StateObject private var composerModel = ComposerModel()
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
                        let newest = chat.messages.last?.id
                        ForEach(chat.messages) { message in
                            // Equatable on the message's revision: while one answer streams in, the earlier messages
                            // (and their Markdown) are not laid out again for every few words.
                            ChatMessageView(message: message, isLast: message.id == newest && !chat.busy, isNewest: message.id == newest, app: app)
                                .equatable()
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

    /// Updates as streamed responses arrive, keeping the chat scrolled to bottom without layout thrashing on every token.
    private var scrollKey: String {
        guard let last = chat.messages.last else { return "" }
        let textStep = last.streaming ? (last.text.count / 24) : last.text.count
        return "\(last.id)-\(last.streaming)-\(textStep)-\(last.charts.count)-\(last.mails.count)-\(last.actions.count)-\(last.status)-\(last.retrieval.count)-\(last.references.count)"
    }

    // MARK: Input

    /// The same composer as the agents: the text on top, a plus menu and two quiet choices underneath, a round send button
    /// on the right. A file you attach shows above the box, only while there is one.
    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let name = app.attachmentName {
                AttachmentChip(name: name) { app.clearAttachment() }
            }
            SessionComposer(
                text: $question,
                prompt: chat.isEmpty ? tr("home.inputPrompt") : tr("chat.followupPrompt"),
                busy: chat.busy,
                onStop: { app.stopChat() },
                focus: $inputFocused,
                onSend: send
            ) {
                // The same row as the agents' choices: a plus menu, then model and sources split by a thin line.
                ComposerMoreMenu(chat: chat)
                BrainChip()
                ComposerDivider()
                ScopeMenu(chat: chat)
            }
            .rich(composerModel, chatComposerConfig)
            .trailing {
                NookIconButton(systemName: "mic", label: tr("button.talk"), size: 30) { viewModel.startListening() }
            }
        }
    }

    /// The chat gets the same box as the agents: commands under `/`, ArrowUp for earlier questions. References stay off:
    /// a question goes to the brain as plain text.
    private var chatComposerConfig: ComposerConfig {
        var config = ComposerConfig()
        config.commands = [ComposerCommand(name: "new", insertion: "", action: .new)]
        config.onCommand = { [app] command in
            if command.action == .new { app.newChat() }
        }
        return config
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerModel.history.record(text)
        question = ""
        app.handleUserText(text)
        inputFocused = true
    }
}

// MARK: Single message

private struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    /// The latest finished answer: the only one you can retry.
    var isLast = false
    /// The newest message: a question at its end can be answered with a click.
    var isNewest = false
    /// Used for the buttons only, deliberately not observed: observing the whole app model redrew every message on
    /// every change anywhere in Nook.
    let app: AppModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: user
        case .nook: nook
        }
    }

    private var user: some View {
        ConversationMessage(fromUser: true, text: message.text, size: 14)
    }

    private var nook: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.isError {
                ChatErrorCard(message: message, canRetry: isLast)
            } else if !message.text.isEmpty {
                ConversationMessage(fromUser: false, text: message.text, size: 14,
                                    onChoose: !message.streaming && isNewest ? { app.handleUserText($0) } : nil)
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

            // Where Nook looked, folded away until you want to see it; a source that failed opens it.
            if !message.isError {
                SourcesDisclosure(message: message, onRetry: isLast ? { app.retryLast() } : nil)
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

    static func == (a: ChatMessageView, b: ChatMessageView) -> Bool {
        a.message.id == b.message.id && a.message.revision == b.message.revision && a.isLast == b.isLast && a.isNewest == b.isNewest
    }
}

/// A calm card for an answer that could not be made: what happened in plain words, the action that fixes it, retry as the
/// second choice, and the raw message behind Details.
private struct ChatErrorCard: View {
    let message: ChatMessage
    let canRetry: Bool
    @EnvironmentObject private var app: AppModel
    @State private var showDetails = false

    private var recovery: ChatRecoveryAction { ChatRecoveryAction.forError(message.text, selection: app.settings.selection) }

    private var explanation: String {
        switch recovery {
        case .chooseModel: return tr("chat.error.chooseModel")
        case .openLocalServer(let runtime): return tr("chat.error.server", runtime == .ollama ? "Ollama" : "LM Studio")
        case .reconnectBrain, .reconnectConnection: return tr("chat.error.credentials")
        case .openSettings: return tr("chat.error.generic")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NookTheme.coralSoft)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(NookTheme.coral.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("chat.error.title"))
                        .font(NookTheme.font(13.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text(explanation)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Button { app.performRecovery(recovery) } label: {
                    Text(app.recoveryTitle(recovery))
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.ink)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(NookTheme.paper))
                }
                .buttonStyle(.plain)
                if canRetry {
                    Button { app.retryLast() } label: {
                        Text(tr("chat.retry"))
                            .font(NookTheme.font(12, .semibold))
                            .foregroundStyle(NookTheme.paper)
                            .padding(.horizontal, 13)
                            .frame(height: 28)
                            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 32)
            Button { withAnimation(.easeOut(duration: 0.16)) { showDetails.toggle() } } label: {
                Text(showDetails ? tr("chat.error.hideDetails") : tr("chat.error.details"))
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 32)
            if showDetails {
                Text(message.text)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
                    .padding(.leading, 32)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NookTheme.coral.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NookTheme.coral.opacity(0.22), lineWidth: 1))
    }
}

/// Three gentle dots while Nook is thinking, along with its current activity.
private struct TypingIndicator: View {
    let status: String

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        let wave = (1.0 + sin(t * 3.2 + Double(i) * 0.7)) / 2.0
                        Circle()
                            .fill(NookTheme.iris)
                            .frame(width: 6, height: 6)
                            .opacity(0.35 + 0.65 * wave)
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

/// Busy (white, breathing), waiting for you (amber), new response (mint), or idle (gray).
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
    @EnvironmentObject private var app: AppModel

    /// The real icon of what the item is about (the agent, the calendar, the connection) with the item's color as a
    /// small dot on it; a plain dot for the rest.
    @ViewBuilder private var marker: some View {
        switch item.logo {
        case .agent(let name):
            AgentLogo(agent: name, size: 18).overlay(alignment: .bottomTrailing) { badge }
        case .source(let id):
            let source = app.connectors.source(id: id)
            SiteIcon(domain: source?.iconDomain, fallback: source?.symbol ?? "circle.grid.2x2", tint: item.color, size: 18, source: id)
                .overlay(alignment: .bottomTrailing) { badge }
        case nil:
            Circle().fill(item.color).frame(width: 8, height: 8)
        }
    }

    private var badge: some View {
        Circle().fill(item.color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(NookTheme.ink, lineWidth: 1.2))
            .offset(x: 2, y: 2)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                marker
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
