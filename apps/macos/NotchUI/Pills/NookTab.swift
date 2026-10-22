import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Nook tab: home and chat in one. An empty conversation shows your day and suggestions; a running one the thread.
struct NookChatTab: View {
    @ObservedObject var viewModel: NotchViewModel
    var openOnAgents: ((String) -> Void)?
    @EnvironmentObject private var app: AppModel

    var body: some View {
        NookChatView(viewModel: viewModel, chat: app.chat, openOnAgents: openOnAgents)
    }
}

/// The chat, shared by the notch and the main window. `compact` is the notch version: a narrower list of Nooks.
struct NookChatView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var chat: NookChat
    var compact = true
    /// Shows the panel footer under the list of Nooks, where Agents has it under its sessions, so the refresh and update
    /// button sits in the same place on both tabs. A footer page (pull requests, usage) opens on Agents through it.
    var openOnAgents: ((String) -> Void)?
    @EnvironmentObject private var app: AppModel
    @State private var question = ""
    @State private var images: [ImageAttachment] = []
    @State private var dropTargeted = false
    @StateObject private var composerModel = ComposerModel()
    @FocusState private var inputFocused: Bool
    /// Follows the answer while it streams, until you scroll away; the same rules as an agent session.
    @State private var scroll = ScrollModel()
    @State private var atEnd = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var renaming = false
    @State private var titleDraft = ""
    /// The conversation whose delete waits for a yes.
    @State private var deleting: Conversation?
    @ObservedObject private var embedded = EmbeddedAppStore.shared
    /// How wide the chat is next to an open app: drag the line between them, double-click it to reset. Remembered.
    @AppStorage("nook.embeddedApp.chatWidth") private var chatWidth = EmbeddedSplit.defaultChatWidth
    @State private var totalWidth: Double = 0
    @State private var dragStartWidth: Double?
    /// How wide the list of Nooks is, in the notch and in the main window: drag the line beside it. Remembered.
    @AppStorage("nook.chat.listWidth") private var listWidth = PanelLayout.chatList
    @AppStorage("nook.chat.windowListWidth") private var windowListWidth = PanelLayout.chatListWindow

    /// An app or Nook's browser is open next to the chat.
    private var sideOpen: Bool { embedded.current != nil || viewModel.browserBesideChat }

    var body: some View {
        // The same split as the Agents tab: the list on the left, a thin line, the conversation on the right. With an app
        // open ("@open whatsapp") the app takes the list's place on the right, and the chat narrows beside it.
        let listShown = (!chat.history.isEmpty || !compact) && !sideOpen
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                if listShown {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                        NookList(chat: chat)
                        footer
                    }
                    .padding(.trailing, compact ? NookTheme.Spacing.xs : NookTheme.Spacing.md)
                    .resizablePanel(width: compact ? $listWidth : $windowListWidth,
                                    defaultWidth: compact ? PanelLayout.chatList : PanelLayout.chatListWindow,
                                    minimum: PanelLayout.minimumList, available: totalWidth,
                                    rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .trailing, divider: true)
                    .padding(.trailing, compact ? NookTheme.Spacing.md : NookTheme.Spacing.lg)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if chat.isEmpty {
                        emptyState
                    } else {
                        header
                            .padding(.bottom, NookTheme.Spacing.xs)
                        thread
                    }
                    inputBar
                        .padding(.top, NookTheme.Spacing.md)
                }
                // In the main window the conversation keeps a readable width, centered in the room beside the list.
                .frame(maxWidth: compact ? nil : PanelLayout.readableChat)
                .frame(maxWidth: compact ? nil : .infinity)
                .frame(width: sideOpen ? EmbeddedSplit.chatWidth(chatWidth, total: totalWidth) : nil)
                if sideOpen {
                    EmbeddedSplitHandle(
                        onDrag: { offset in
                            let start = dragStartWidth ?? EmbeddedSplit.chatWidth(chatWidth, total: totalWidth)
                            dragStartWidth = start
                            chatWidth = EmbeddedSplit.chatWidth(start + offset, total: totalWidth)
                        },
                        onEnd: { dragStartWidth = nil },
                        onReset: { chatWidth = EmbeddedSplit.defaultChatWidth }
                    )
                    if embedded.current != nil {
                        EmbeddedAppPane()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        BrowserView(onClose: { viewModel.browserBesideChat = false })
                            .background(NookTheme.field)
                            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.sheet, style: .continuous))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            // No list beside the chat (a first chat, or an app open): the footer keeps the list's width at the bottom.
            if !listShown && showsFooter {
                footer
                    .frame(width: min(compact ? listWidth : windowListWidth, max(totalWidth, PanelLayout.minimumList)))
                    .padding(.top, NookTheme.Spacing.md)
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: NookTheme.Radius.sheet)
                    .strokeBorder(NookTheme.iris, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .overlay(Text(tr("chat.dropFile")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper))
                    .allowsHitTesting(false)
            }
        }
        // Drop a file anywhere on the chat: Nook reads it and you ask about it (this replaces the old Shelf tab).
        // A picture is added to the message instead; it goes to the model with your question.
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropTargeted) { providers in
            ImageAttachment.receive(Array(providers.prefix(6)), images: { images += $0 }, file: { app.askAbout($0) })
        }
        .onAppear {
            // What you were typing when the notch closed is back, pictures included.
            if question.isEmpty, let saved = ComposerDraftStore.shared.draft(for: Self.draftKey) { question = saved }
            if images.isEmpty { images = NookTabDraft.images }
            // Wait briefly for the panel to acquire keyboard focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { inputFocused = true }
        }
        .onChange(of: question) { _, text in ComposerDraftStore.shared.save(sessionID: Self.draftKey, text: text) }
        .onDisappear { NookTabDraft.images = images }
    }

    /// The key of the question you were typing in `ComposerDraftStore`.
    static let draftKey = "nook-chat"

    private var showsFooter: Bool { openOnAgents != nil && !app.demoMode }

    @ViewBuilder
    private var footer: some View {
        if let openOnAgents, showsFooter {
            PanelFooter(selected: "", open: openOnAgents, openSettings: { app.openSettings() }, history: app.history)
        }
    }

    // MARK: Empty chat: your day and where to start

    /// The date, a greeting that counts what waits, then two quiet sections: "For you" (the Today rows in one card) and
    /// "Start with" (starters built from your real data, two per row). It scrolls when the notch is short.
    private var emptyState: some View {
        let items = Array(app.todayItems.prefix(compact ? 3 : 6))
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    Text(Self.dateLine())
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(items.isEmpty ? Greeting.quiet() : Greeting.line(count: items.count))
                        .font(NookTheme.TextStyle.display)
                        .foregroundStyle(NookTheme.paper)
                }
                .padding(.horizontal, NookTheme.Spacing.xxs)

                if !items.isEmpty {
                    homeSection(tr("home.section.forYou"))
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                NookDivider(inset: 56)
                            }
                            TodayRow(item: item) { open(item) }
                        }
                    }
                    .panelCard()
                }

                homeSection(tr("home.section.start"))
                suggestions
            }
            .padding(.bottom, NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func homeSection(_ title: String) -> some View {
        NookSectionLabel(title, inset: NookTheme.Spacing.xxs)
            .padding(.top, NookTheme.Spacing.xxl)
            .padding(.bottom, NookTheme.Spacing.md)
    }

    /// "Monday 19 October", in the app's language.
    private static func dateLine() -> String {
        let line = NookDates.formatter("EEEE d MMMM", locale: I18n.shared.currentLanguage.rawValue).string(from: Date())
        return line.prefix(1).uppercased() + line.dropFirst()
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

    /// The conversation's title (double-click to rename it), the status while it works, and the conversation's menu on
    /// the right. The tab and the list already say this is Nook, so the title stands on its own.
    @ViewBuilder
    private var header: some View {
        if let conversation = chat.active {
            HStack(spacing: NookTheme.Spacing.md) {
                if renaming {
                    TextField(tr("ws.title.placeholder"), text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.title)
                        .foregroundStyle(NookTheme.paper)
                        .onSubmit {
                            chat.rename(conversation.id, to: titleDraft)
                            renaming = false
                        }
                        .onExitCommand { renaming = false }
                } else {
                    Text(conversation.title)
                        .font(NookTheme.TextStyle.title)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                        .onTapGesture(count: 2) { startRenaming(conversation) }
                        .help(tr("ws.title.renameHelp"))
                }
                if conversation.pinned {
                    Image(systemName: "pin.fill").font(NookTheme.font(9)).foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: NookTheme.Spacing.md)
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
            .frame(height: 30)
            .padding(.leading, NookTheme.Spacing.xxs)
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
                Pasteboard.copy(ChatExport.markdown(conversation))
            }
            Divider()
            Button(tr("nooks.archive")) { chat.setArchived(true, conversation.id) }
                .disabled(conversation.busy)
            Button(tr("nooks.delete"), role: .destructive) { deleting = conversation }
                .disabled(conversation.busy)
        } label: {
            Image(systemName: "ellipsis")
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .composerMenu()
        .help(tr("chat.moreActions"))
        .accessibilityLabel(tr("chat.moreActions"))
        .confirmDelete($deleting, question: { tr("confirm.deleteChat", $0.title) }, detail: tr("confirm.deleteChat.detail"),
                       confirmTitle: tr("nooks.delete")) { chat.delete($0.id) }
    }

    // MARK: Conversation

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                // Wide gaps between turns, so each question and its answer read as one block.
                LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxl) {
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
                .padding(.horizontal, NookTheme.Spacing.xxs)
                .padding(.top, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.xs)
                .animation(NookTheme.reveal, value: chat.messages.count)
            }
            .defaultScrollAnchor(.bottom)
            // Scrolling away from the end stops the following until you come back, or jump back with the pill.
            // Moving up while the sizes stay the same can only be you (following only ever moves down), so this also
            // catches a mouse wheel, and a scroll that starts at the end before it leaves it.
            .onScrollGeometryChange(for: ThreadScrollGeometry.self) { geometry in
                ThreadScrollGeometry(offset: geometry.contentOffset.y,
                                     container: geometry.containerSize.height,
                                     content: geometry.contentSize.height)
            } action: { old, new in
                atEnd = new.atEnd
                if new.offset < old.offset - 0.5, new.content == old.content, new.container == old.container, !new.atEnd {
                    scroll.userScrolled()
                } else if new.atEnd {
                    scroll.reachedEnd()
                }
            }
            .onScrollPhaseChange { _, phase in
                scrollPhase = phase
                if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
            }
            .onChange(of: atEnd) { _, nowAtEnd in
                if !nowAtEnd, scrollPhase == .interacting || scrollPhase == .decelerating { scroll.userScrolled() }
            }
            // The lazy rows only learn their real height once laid out, and the notch is still growing while it opens:
            // as long as we follow the end, every change in size is caught up with, so the chat never opens halfway up.
            .onScrollGeometryChange(for: [Double].self) { geometry in
                [geometry.containerSize.height, geometry.contentSize.height]
            } action: { _, _ in
                if scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if scroll.mode == .free, !atEnd {
                    TimelineToEndPill {
                        scroll.jumpedToEnd()
                        withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
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
            // Opening the chat or another conversation: start at its end and follow again.
            .onAppear { settleAtEnd(proxy) }
            .onChange(of: chat.activeID) { _, _ in settleAtEnd(proxy) }
            // You asked something: it is the newest thing and the answer is followed again.
            .onChange(of: chat.messages.last(where: { $0.role == .user })?.id) { _, _ in
                scroll.jumpedToEnd()
                withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: scrollKey) { _, _ in
                if scroll.shouldFollowEnd { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Scrolls to the end now and again while the layout settles (rows measured, the notch done opening), unless you
    /// scroll away in the meantime.
    private func settleAtEnd(_ proxy: ScrollViewProxy) {
        scroll.jumpedToEnd()
        proxy.scrollTo("bottom", anchor: .bottom)
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
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
                NookIconButton(systemName: "mic", label: tr("button.talk"), size: 32) { viewModel.startListening() }
            }
            .images($images, asPaths: false, onFile: { app.askAbout($0) })
        }
    }

    /// The chat gets the same box as the agents: commands under `/`, ArrowUp for earlier questions. References stay off:
    /// a question goes to the brain as plain text.
    private var chatComposerConfig: ComposerConfig {
        var config = ComposerConfig()
        // `@` lists the apps that open next to the chat: the Mac apps on this Mac and the web apps.
        config.apps = EmbeddedAppCatalog.available().map { (id: $0.id, title: $0.title, symbol: $0.symbol) }
        // "@chat …" lists the chats of every chat app, so you open the one you mean.
        config.chats = { [app] in app.chatChoices() }
        config.openApp = { [viewModel] in viewModel.embeddedAppOpen ? EmbeddedAppStore.shared.current?.title : nil }
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

/// Where the chat thread is scrolled, to tell your own scrolling apart from following the end.
private struct ThreadScrollGeometry: Equatable {
    var offset: Double
    var container: Double
    var content: Double

    var atEnd: Bool { offset + container >= content - 48 }
}

/// The pictures waiting in the chat's box when the notch closed; the text itself goes to `ComposerDraftStore`.
@MainActor
private enum NookTabDraft {
    static var images: [ImageAttachment] = []
}
