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
    @State private var images: [ImageAttachment] = []
    @State private var dropTargeted = false
    @StateObject private var composerModel = ComposerModel()
    @FocusState private var inputFocused: Bool
    /// Follows the answer while it streams, until you scroll away; the same rules as an agent session.
    @State private var scroll = ScrollModel()
    @State private var atEnd = true
    @State private var renaming = false
    @State private var titleDraft = ""

    var body: some View {
        // The same split as the Agents tab: the list on the left, a thin line, the conversation on the right.
        HStack(alignment: .top, spacing: 0) {
            if !chat.history.isEmpty || !compact {
                NookList(chat: chat)
                    .frame(width: compact ? 200 : 260)
                Rectangle().fill(Color(hex: 0x19191B)).frame(width: 1)
                    .padding(.horizontal, compact ? 12 : 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                if chat.isEmpty {
                    emptyState
                } else {
                    header
                        .padding(.bottom, 8)
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
        // A picture is added to the message instead; it goes to the model with your question.
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            ImageAttachment.receive(Array(providers.prefix(6)), images: { images += $0 }, file: { app.askAbout($0) })
        }
        .onAppear {
            // Wait briefly for the panel to acquire keyboard focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { inputFocused = true }
        }
    }

    // MARK: Empty chat: your day and where to start

    /// The date, a greeting that counts what waits, then two quiet sections: "For you" (the Today rows in one card) and
    /// "Start with" (starters built from your real data, two per row). It scrolls when the notch is short.
    private var emptyState: some View {
        let items = Array(app.todayItems.prefix(compact ? 3 : 6))
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.dateLine())
                        .font(NookTheme.font(11, .semibold))
                        .tracking(0.6)
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(items.isEmpty ? Greeting.quiet() : Greeting.line(count: items.count))
                        .font(NookTheme.font(22, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text(tr("chat.emptySubtitle"))
                        .font(NookTheme.font(13))
                        .foregroundStyle(NookTheme.textSecondary)
                }

                if !items.isEmpty {
                    homeSection(tr("home.section.forYou"))
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Rectangle().fill(NookTheme.line).frame(height: 1).padding(.leading, 56)
                            }
                            TodayRow(item: item) { open(item) }
                        }
                    }
                    .background(NookTheme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NookTheme.line2.opacity(0.6), lineWidth: 1))
                }

                homeSection(tr("home.section.start"))
                suggestions
            }
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func homeSection(_ title: String) -> some View {
        Text(title)
            .font(NookTheme.font(11.5, .medium))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.leading, 2)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    /// "MONDAY 19 OCTOBER", in the app's language.
    private static func dateLine() -> String {
        NookDates.formatter("EEEE d MMMM", locale: I18n.shared.currentLanguage.rawValue).string(from: Date()).uppercased()
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
        SuggestionGrid(suggestions: app.startSuggestions) { app.handleUserText($0.text) }
    }

    // MARK: Header

    /// "Nook / Plan my Friday" (double-click the name to rename it), the status while it works, and the conversation's
    /// menu on the right: the same header as an agent session.
    @ViewBuilder
    private var header: some View {
        if let conversation = chat.active {
            HStack(spacing: 8) {
                Text(tr("tab.nook"))
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize()
                Text("/").foregroundStyle(NookTheme.textTertiary)
                if renaming {
                    TextField(tr("ws.title.placeholder"), text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(NookTheme.font(13.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .onSubmit {
                            chat.rename(conversation.id, to: titleDraft)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                } else {
                    Text(conversation.title)
                        .font(NookTheme.font(13.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { startRenaming(conversation) }
                        .help(tr("ws.title.renameHelp"))
                }
                if conversation.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 8)
                if conversation.busy, let since = conversation.turnStarted {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        AgentStatusBadge(state: .working, detail: AgentFormat.short(context.date.timeIntervalSince(since)))
                    }
                } else if conversation.status == .waiting {
                    AgentStatusBadge(state: .approval)
                }
                // A new Nook starts from the list's header (⌘N), which is always next to a conversation.
                conversationMenu(conversation)
            }
            .font(NookTheme.font(13.5))
            .frame(height: 30)
            .onChange(of: chat.activeID) { _, _ in renaming = false }
        }
    }

    private func startRenaming(_ conversation: Conversation) {
        titleDraft = conversation.title
        renaming = true
    }

    /// Everything else you can do with this conversation, as in a session's menu.
    private func conversationMenu(_ conversation: Conversation) -> some View {
        Menu {
            Button(tr("nooks.rename")) { startRenaming(conversation) }
            Button(tr(conversation.pinned ? "nooks.unpin" : "nooks.pin")) { chat.togglePin(conversation.id) }
            Button(tr("ws.export.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ChatExport.markdown(conversation), forType: .string)
            }
            Divider()
            Button(tr("nooks.archive")) { chat.setArchived(true, conversation.id) }
                .disabled(conversation.busy)
            Button(tr("nooks.delete"), role: .destructive) { chat.delete(conversation.id) }
                .disabled(conversation.busy)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .composerMenu()
        .help(tr("chat.moreActions"))
        .accessibilityLabel(tr("chat.moreActions"))
    }

    // MARK: Conversation

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let newest = chat.messages.last?.id
                    ForEach(chat.messages) { message in
                        // Equatable on the message's revision: while one answer streams in, the earlier messages
                        // (and their Markdown) are not laid out again for every few words.
                        ChatMessageView(message: message, isLast: message.id == newest && !chat.busy, isNewest: message.id == newest, app: app)
                            .equatable()
                            .id(message.id)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.trailing, 4)
                .padding(.top, 8)
                .animation(.easeOut(duration: 0.2), value: chat.messages.count)
            }
            .defaultScrollAnchor(.bottom)
            // Scrolling away from the end stops the following until you come back, or jump back with the pill.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
            } action: { _, nowAtEnd in
                atEnd = nowAtEnd
                if nowAtEnd { scroll.reachedEnd() }
            }
            .onScrollPhaseChange { _, phase in
                if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
            }
            .overlay(alignment: .bottom) {
                if scroll.mode == .free, !atEnd {
                    TimelineToEndPill {
                        scroll.jumpedToEnd()
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                }
            }
            // A soft fade under the header, so text scrolls away instead of being cut off.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Color.black
                }
            )
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            // Another conversation: start at its end and follow again.
            .onChange(of: chat.activeID) { _, _ in
                scroll.jumpedToEnd()
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // You asked something: it is the newest thing and the answer is followed again.
            .onChange(of: chat.messages.last(where: { $0.role == .user })?.id) { _, _ in
                scroll.jumpedToEnd()
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: scrollKey) { _, _ in
                if scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
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
                AttachmentChip(name: name, isImage: app.attachmentIsImage) { app.clearAttachment() }
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
            .images($images, asPaths: false, onFile: { app.askAbout($0) })
        }
    }

    /// The chat gets the same box as the agents: commands under `/`, ArrowUp for earlier questions. References stay off:
    /// a question goes to the brain as plain text.
    private var chatComposerConfig: ComposerConfig {
        var config = ComposerConfig()
        config.commands = AgentCommands.commands(for: .claude, hasProject: false, surface: .chat).filter { $0.action == .new }
        config.onCommand = { [app] command in
            if command.action == .new { app.newChat() }
        }
        return config
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        composerModel.history.record(text)
        let attached = images
        question = ""
        images = []
        app.handleUserText(text, images: attached)
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
        VStack(alignment: .trailing, spacing: 6) {
            if !message.images.isEmpty {
                ImageMessageRow(images: message.images)
            }
            if !message.text.isEmpty {
                ConversationMessage(fromUser: true, text: message.text, size: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var nook: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.isError {
                ChatErrorCard(message: message, canRetry: isLast)
            } else if !message.text.isEmpty {
                ConversationMessage(fromUser: false, text: message.text, size: 14,
                                    onChoose: !message.streaming && isNewest ? { app.handleUserText($0) } : nil)
            } else if message.streaming && message.charts.isEmpty && message.mails.isEmpty {
                TypingIndicator(status: message.status, since: message.date)
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
                        OfferChip(text: offer) { app.handleUserText(offer) }
                    }
                }
            }

            if message.streaming && !message.text.isEmpty && !message.status.isEmpty {
                TypingIndicator(status: message.status, since: message.date)
            }

            if !message.streaming && !message.isError && !message.text.isEmpty {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Under a finished answer, on hover: copy, try again (the newest answer only) and when it was written. The row keeps
    /// its place when hidden, so nothing jumps when the pointer moves over the thread.
    private var actionRow: some View {
        HStack(spacing: 2) {
            messageAction(copied ? "checkmark" : "doc.on.doc", copied ? tr("button.copied") : tr("button.copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            if isLast {
                messageAction("arrow.clockwise", tr("chat.retry")) { app.retryLast() }
            }
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.leading, 4)
        }
        .opacity(hovering || copied ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .padding(.top, -4)
    }

    private func messageAction(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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

/// What Nook is doing right now, as an agent session shows it: a pulsing dot, the current step shimmering, and how long
/// the answer has been going.
private struct TypingIndicator: View {
    let status: String
    /// When the answer started.
    var since: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String { status.isEmpty ? tr("chat.thinking") : status }

    var body: some View {
        HStack(spacing: 8) {
            PulseDot(color: NookTheme.iris, animated: !reduceMotion)
                .frame(width: 14, height: 14)
            Group {
                if reduceMotion {
                    Text(label).foregroundStyle(NookTheme.textSecondary)
                } else {
                    ShimmerText(text: label)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    // Only once it takes a moment: a quick answer should not flash a timer.
                    if elapsed >= 3 {
                        Text(AgentPathFormat.duration(elapsed))
                            .foregroundStyle(NookTheme.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(NookTheme.font(12.5))
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A next step Nook offers under its answer: one click asks it.
private struct OfferChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                Text(text)
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("Nook: \(text)")
    }
}

/// A conversation as Markdown, to paste elsewhere: who said what, in order.
enum ChatExport {
    static func markdown(_ conversation: Conversation) -> String {
        var parts = ["# " + conversation.title]
        for message in conversation.messages where !message.text.isEmpty {
            let author = message.role == .user ? tr("chat.you") : "Nook"
            parts.append("**\(author)**\n\n" + message.text)
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: Your Nooks

/// All your Nooks, listed the way the Agents tab lists sessions: a header with the new-Nook button, a search, pinned
/// conversations first, then the rest, and the archive folded away at the bottom. Each row is a card with the title,
/// the status as the same badge the agents use (working, needs you, new answer) or how long ago, and the last answer
/// underneath. Pin and archive appear on hover, in the badge's place, so nothing shifts; right-click for the rest.
private struct NookList: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: UUID?
    @State private var nameDraft = ""

    var body: some View {
        let items = chat.list(query: query, showArchived: false)
        let archived = chat.list(query: query, showArchived: true)
        let pinned = items.filter(\.pinned)
        let rest = items.filter { !$0.pinned }
        VStack(alignment: .leading, spacing: 8) {
            header
            searchField
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        if items.isEmpty && (archived.isEmpty || !showArchived) {
                            Text(query.isEmpty ? tr("nooks.none") : tr("nooks.noMatches"))
                                .font(NookTheme.font(12.5))
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(12)
                        }
                        if !pinned.isEmpty {
                            sectionLabel(tr("nooks.section.pinned"))
                            rows(pinned, now: context.date)
                            if !rest.isEmpty {
                                sectionLabel(tr("nooks.section.recent")).padding(.top, 8)
                            }
                        }
                        rows(rest, now: context.date)
                        if !archived.isEmpty {
                            archiveShelf(archived, now: context.date)
                        }
                    }
                }
            }
        }
    }

    // MARK: Header and search

    /// "Nook" with the button that starts a new one, as "Agents" has.
    private var header: some View {
        HStack(spacing: 8) {
            Text(tr("tab.nook"))
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Spacer(minLength: 4)
            Button { app.newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(chat.isEmpty ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(chat.isEmpty ? NookTheme.smoke : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help(tr("nooks.newHelp"))
            .accessibilityLabel(tr("nooks.new"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
            TextField(tr("nooks.search"), text: $query)
                .textFieldStyle(.plain)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.paper)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("button.clear"))
            }
        }
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NookTheme.field))
        .padding(.horizontal, 2)
    }

    // MARK: Sections

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(NookTheme.font(11.5, .medium))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }

    /// The archive as a shelf, like the settled sessions: a line with its count, opened with a click.
    private func archiveShelf(_ archived: [Conversation], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showArchived.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(tr("nooks.section.archived", archived.count))
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize()
                    Rectangle().fill(NookTheme.line2).frame(height: 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(showArchived ? 0 : -90))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showArchived ? tr("compose.queue.expanded") : "")
            if showArchived {
                rows(archived, now: now)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func rows(_ conversations: [Conversation], now: Date) -> some View {
        ForEach(conversations) { conversation in
            if renaming == conversation.id {
                TextField("", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x17171A)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NookTheme.iris.opacity(0.5), lineWidth: 1))
                    .onSubmit {
                        chat.rename(conversation.id, to: nameDraft)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                NookRow(conversation: conversation, selected: conversation.id == chat.activeID, now: now,
                        onPin: { chat.togglePin(conversation.id) },
                        onArchive: { chat.setArchived(!conversation.archived, conversation.id) }) {
                    app.openConversation(conversation.id)
                }
                .contextMenu { contextMenu(conversation) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ conversation: Conversation) -> some View {
        Button(tr("nooks.rename")) {
            nameDraft = conversation.title
            renaming = conversation.id
        }
        if !conversation.archived {
            Button(tr(conversation.pinned ? "nooks.unpin" : "nooks.pin")) { chat.togglePin(conversation.id) }
        }
        Button(tr("ws.export.copy")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ChatExport.markdown(conversation), forType: .string)
        }
        Button(tr(conversation.archived ? "nooks.unarchive" : "nooks.archive")) {
            chat.setArchived(!conversation.archived, conversation.id)
        }
        .disabled(conversation.busy)
        Divider()
        Button(tr("nooks.delete"), role: .destructive) { chat.delete(conversation.id) }
            .disabled(conversation.busy)
    }
}

/// One Nook in the list, built like a session row in the Agents tab: a soft card, the title with the status on the
/// right, the last answer underneath. A conversation that asks nothing of you recedes, so what needs you stands out.
private struct NookRow: View {
    let conversation: Conversation
    let selected: Bool
    let now: Date
    let onPin: () -> Void
    let onArchive: () -> Void
    let action: () -> Void
    @State private var hovering = false

    private var background: Color { selected ? Color(hex: 0x17171A) : (hovering ? Color(hex: 0x111113) : Color(hex: 0x09090A)) }
    private var receded: Bool { conversation.status == .idle && !selected }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.plain)
            hoverActions
                .padding(.top, 8)
                .padding(.trailing, 8)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title), \(statusText)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(conversation.title)
                    .font(NookTheme.font(13.5, receded ? .regular : .medium))
                    .foregroundStyle(receded || conversation.archived ? NookTheme.textSecondary : NookTheme.paper)
                    .lineLimit(1)
                if conversation.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 6)
                slot.opacity(hovering ? 0 : 1)
            }
            Text(conversation.preview.isEmpty ? statusText : conversation.preview)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .contentShape(Rectangle())
    }

    /// The status as the agents show it, otherwise how long ago.
    @ViewBuilder
    private var slot: some View {
        switch conversation.status {
        case .working:
            AgentStatusBadge(state: .working, detail: conversation.turnStarted.map { AgentFormat.short(now.timeIntervalSince($0)) })
        case .waiting:
            AgentStatusBadge(state: .approval)
        case .unread:
            AgentStatusBadge(state: .ready)
        case .idle:
            Text(AgentFormat.short(now.timeIntervalSince(conversation.updated)))
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize()
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if !conversation.archived {
                rowButton(conversation.pinned ? "pin.slash" : "pin", tr(conversation.pinned ? "nooks.unpin" : "nooks.pin"), onPin)
            }
            if !conversation.busy {
                rowButton(conversation.archived ? "tray.and.arrow.up" : "archivebox",
                          tr(conversation.archived ? "nooks.unarchive" : "nooks.archive"), onArchive)
            }
        }
    }

    private func rowButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var statusText: String {
        switch conversation.status {
        case .working: return tr("nooks.working")
        case .waiting: return tr("nooks.waiting")
        case .unread: return tr("nooks.doneAt", NookDates.ago(conversation.updated))
        case .idle: return NookDates.ago(conversation.updated)
        }
    }
}

// MARK: Starters

/// Suggested conversation starters, two per row so a long one never runs off the side.
private struct SuggestionGrid: View {
    let suggestions: [StartSuggestion]
    let ask: (StartSuggestion) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(suggestions) { suggestion in
                SuggestionCard(suggestion: suggestion) { ask(suggestion) }
            }
        }
    }
}

/// One starter: the icon of what it is about and the question; it brightens and shows an arrow under the pointer.
private struct SuggestionCard: View {
    let suggestion: StartSuggestion
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HomeLogo(logo: suggestion.logo, tint: NookTheme.textSecondary, size: 26)
                Text(suggestion.text)
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : Color(hex: 0xD9D7E0))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? NookTheme.graphite : NookTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hovering ? NookTheme.line2 : NookTheme.line2.opacity(0.6), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The icon in front of a Today row or a starter, always in a box of the same size so the text beside it lines up:
/// a connection's own icon, an agent's logo, or a symbol on a soft tile in the item's color.
private struct HomeLogo: View {
    let logo: TodayItem.Logo?
    var tint: Color
    var size: CGFloat = 30
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch logo {
            case .agent(let name):
                AgentLogo(agent: name, size: size * 0.62)
            case .source(let id):
                let source = app.connectors.source(id: id)
                SiteIcon(domain: source?.iconDomain, fallback: source?.symbol ?? "circle.grid.2x2", tint: tint, size: size * 0.62, source: id)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(tint)
            case nil:
                Circle().fill(tint).frame(width: 8, height: 8)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tileFill))
    }

    /// Symbols and dots sit on a tile tinted with their color; real icons get a neutral one.
    private var tileFill: Color {
        switch logo {
        case .symbol, nil: return tint.opacity(0.12)
        case .agent, .source: return NookTheme.paper.opacity(0.05)
        }
    }
}

private struct TodayRow: View {
    let item: TodayItem
    let action: () -> Void
    @State private var hovering = false

    /// A connection or agent keeps its own icon, with the item's color as a small dot on its corner.
    private var hasBadge: Bool {
        switch item.logo {
        case .agent, .source: return true
        case .symbol, nil: return false
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HomeLogo(logo: item.logo, tint: item.color)
                    .overlay(alignment: .bottomTrailing) {
                        if hasBadge {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(NookTheme.field, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NookTheme.font(13.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !item.action.isEmpty {
                    HStack(spacing: 4) {
                        Text(item.action)
                            .font(NookTheme.font(12, .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.paper.opacity(0.05)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(hovering ? NookTheme.paper.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
