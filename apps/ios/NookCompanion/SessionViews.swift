import SwiftUI

// MARK: One session

/// A session as a conversation: a header with where it works, the messages, the agent's steps folded into groups,
/// what waits on you, and a field to reply.
struct SessionDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    /// The suggested next message you closed: it stays away until the Mac suggests another.
    @State private var dismissedPrompt: String?
    @State private var message = ""
    @State private var confirmStop = false
    @State private var confirmArchive = false
    @State private var confirmEnd = false
    @State private var renaming = false
    @State private var newName = ""
    /// While the agent works, what a message does: steer the running turn now, or wait in line for after it. Remembered,
    /// as the Mac's "While the agent works" setting.
    @AppStorage("nook.companion.steerByDefault") private var steerByDefault = false
    /// Pictures that go with the next message.
    @State private var images: [CompanionImage] = []
    /// A file dropped on the session that goes with the next message (`CompanionFeature.attachments`).
    @State private var files: [CompanionFile] = []
    /// The session's changes are open (`SessionChangesView`).
    @State private var reviewing = false
    /// The keyboard is in the composer (after "Reply" on an answer).
    @FocusState private var composerFocused: Bool

    /// From the live list, or an older session opened from the settled ones or a search.
    private var session: SessionDigest? { client.session(sessionID) }
    private var entries: [TimelineEntry] { client.conversation(sessionID) }
    /// An older page is on its way (`CompanionClient.loadEarlier`).
    @State private var loadingEarlier = false
    /// The Mac was asked for a session the list does not hold yet (one just started, a link from a notification).
    @State private var lookedUp = false
    /// The screen's width, so the title in the bar stays clear of the buttons beside it (`SessionHeaderTitle.width`).
    @State private var barWidth: CGFloat = 0
    /// Find in the conversation (the Mac's ⌘F in a session): the words, and which match is shown.
    @State private var finding = false
    @State private var findText = ""
    @State private var findIndex = 0

    var body: some View {
        if let session {
            ConversationScroll(followKey: followKey(session), floatingRoom: floatingRoom(session)) { scroll in
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if client.can(CompanionFeature.timeline), !entries.isEmpty {
                        if client.canReadFullTranscript, !client.reachedStart.contains(sessionID) {
                            EarlierMessagesButton(loading: loadingEarlier) { loadEarlier(scroll) }
                        }
                        TranscriptConversation(sessionID: sessionID, entries: entries, working: session.attention == "working",
                                               found: finding ? currentMatch : nil)
                            // The match shown: in sight, in the middle of the screen.
                            .onChange(of: finding ? currentMatch : nil) { _, match in
                                guard let match else { return }
                                let rows = TranscriptRow.rows(entries, working: session.attention == "working")
                                if let row = rows.first(where: { $0.holds(match) }) {
                                    withAnimation(Theme.reveal) { scroll.scrollTo(row.id, anchor: .center) }
                                }
                            }
                            // "Reply" on an answer: a quote of it at the top of the message, where you can write one.
                            .environment(\.replyToAnswer, client.allows(.operate) && session.canSend != false ? { answer in
                                message = AnswerReply.inserting(AnswerReply.quote(answer), into: message).text
                                composerFocused = true
                            } : nil)
                    } else if !session.excerpt.isEmpty {
                        SectionHeader(title: String(localized: "Latest reply"))
                        TranscriptReply(text: session.excerpt, footer: false)
                    } else if client.can(CompanionFeature.timeline) {
                        if client.isOffline {
                            OfflineNote(text: String(localized: "This conversation is not kept on this iPhone yet. It opens once your Mac is connected."))
                                .padding(.top, Theme.Spacing.xxl)
                                .appearsAfterDelay()
                        } else {
                            TranscriptLoading()
                        }
                    }
                    // Messages that wait in the outbox until the Mac takes them.
                    let waiting = client.outbox.waiting(for: session.id)
                    ForEach(waiting) { entry in
                        TranscriptUserMessage(text: entry.request.text ?? "", pending: true)
                    }
                    // How the session ended when it needs a next step: a usage limit, a failed turn, or settled.
                    if waiting.isEmpty, session.items.isEmpty { SessionEndCard(session: session) }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.lg)
                .readingColumn()
            } floating: {
                FloatingWorkingControl(
                    workingSince: entries.last(where: { $0.kind == .user }).map { Date(timeIntervalSince1970: $0.date) },
                    working: session.attention == "working",
                    snoozed: actions(session).contains(.unsnooze),
                    onWake: { manage(session, .unsnooze) })
            } dock: { scroll in
                dock(session, scroll)
            }
            // Pictures, a file, links and text dragged onto the session wait in its composer (`composerDrop`).
            .safeAreaInset(edge: .top, spacing: 0) {
                if finding {
                    FindBar(text: $findText, index: findIndex, count: matches.count,
                            step: { step in
                                guard !matches.isEmpty else { return }
                                findIndex = (findIndex + step + matches.count) % matches.count
                            },
                            close: {
                                withAnimation(Theme.reveal) { finding = false }
                                findText = ""
                            })
                    .readingColumn()
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // New words start at the newest match, where you were reading.
            .onChange(of: findText) { _, _ in findIndex = max(0, matches.count - 1) }
            .composerDrop(text: $message, images: dropImages, files: dropFiles,
                          enabled: client.allows(.operate) && session.canSend != false && session.items.isEmpty)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The Mac's session header: "folder / title ⌄", the title opening what you can do with the session, and
                // the agent and branch under it.
                ToolbarItem(placement: .principal) {
                    let width = SessionHeaderTitle.width(bar: barWidth, buttons: trailingButtons)
                    if hasActions(session) {
                        manageMenu(session) { SessionHeaderTitle(session: session, opens: true, maxWidth: width) }
                    } else {
                        SessionHeaderTitle(session: session, opens: false, maxWidth: width)
                    }
                }
                if client.can(CompanionFeature.diff) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { reviewing = true } label: { Image(icon: "plusminus").foregroundStyle(Theme.paper) }
                            .accessibilityLabel("Changes")
                    }
                }
            }
            .confirmationDialog("Archive this session?", isPresented: $confirmArchive, titleVisibility: .visible) {
                Button("Archive", role: .destructive) { manage(session, .archive) }
            }
            .confirmationDialog("End this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End session", role: .destructive) { manage(session, .end) }
            } message: {
                Text("The agent saves its conversation, so you can continue it in Nook.")
            }
            .alert("Rename", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Save") { manage(session, .rename, text: newName) }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the session", role: .destructive) { Task { await client.stop(session) } }
            }
            .screen()
            .background { GeometryReader { proxy in Color.clear.onAppear { barWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in barWidth = new } } }
            .modifier(SessionWorkspaceMenu(sessionID: sessionID))
            .navigationDestination(isPresented: $reviewing) {
                // A comment on a line goes into this session's message, under what you wrote.
                SessionChangesView(sessionID: sessionID) { comment in
                    let intro = "Review comments on your changes. Address each one:"
                    let current = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    message = (current.isEmpty ? intro : current) + "\n\n" + comment
                }
            }
            // A push about this session arrives without a banner while it is on screen.
            .onAppear {
                client.visibleSession = sessionID
                // `-NookDemoFind <words>` with `-NookDemo`: the session opens with find showing those words.
                if CompanionClient.isDemo, let words = UserDefaults.standard.string(forKey: "NookDemoFind") {
                    finding = true
                    findText = words
                }
                // Opened to write to it: the keyboard comes up once the screen has slid in. Taken whichever session
                // opens, so a request whose screen never came up does not surface later.
                let wanted = client.focusComposer == sessionID
                client.focusComposer = nil
                if wanted, client.allows(.operate), session.canSend != false {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        composerFocused = true
                    }
                }
            }
            // The models of this session's agent, for the model menu in the composer (the same list as a new session's).
            .task(id: actions(session).contains(.model)) {
                if actions(session).contains(.model), client.launchOptions == nil { await client.loadLaunchOptions() }
            }
            .onDisappear {
                if client.visibleSession == sessionID { client.visibleSession = nil }
                Task { await client.unwatchSession(sessionID) }
            }
            // While the session is on screen its conversation stays current: live from a Mac that sends it by itself
            // (`watchSession`), else asked for every few seconds. Leaving the screen ends the loop.
            .task {
                var live = await client.watchSession(sessionID)
                while !Task.isCancelled {
                    // Opened while the Mac could not be reached: once it is back, follow live from then on.
                    if !live, client.timelineIsLive { live = await client.watchSession(sessionID) }
                    let following = live && client.timelineIsLive
                    if !following { await client.loadTimeline(sessionID) }
                    let working = client.sessions.first { $0.id == sessionID }?.attention == "working"
                    // Following live costs nothing here; the short wait only notices a dropped connection quickly.
                    try? await Task.sleep(for: .seconds(following ? 3 : (working ? 2 : 5)))
                }
            }
        } else if !lookedUp {
            // A session that was just started (or opened from a notification) can be on the Mac before it is in the
            // phone's list: ask for the list straight away, and once more after a moment, before calling it gone.
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                .screen()
                .task {
                    await client.refresh()
                    if client.session(sessionID) == nil {
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { await client.refresh() }
                    }
                    lookedUp = true
                }
        } else {
            WSEmptyState(symbol: "tray", title: String(localized: "This session is gone."), message: String(localized: "It was closed or archived on your Mac."))
                .screen()
        }
    }

    /// Changes when something new comes in at the end: an entry, text streaming into the last one, what waits on you,
    /// a message waiting in the outbox.
    private func followKey(_ session: SessionDigest) -> [String] {
        let last = entries.last
        return [last?.id ?? "", String(last.map { client.fullTexts[$0.id] ?? $0.text }?.count ?? 0), String(entries.count),
                String(session.items.count), String(client.outbox.waiting(for: session.id).count), session.attention]
    }

    /// Room under the last message for the floating "Working for 12s" or "Snoozed", so it never covers the end.
    private func floatingRoom(_ session: SessionDigest) -> CGFloat {
        session.attention == "working" || actions(session).contains(.unsnooze) ? 56 : Theme.Spacing.lg
    }

    /// What a drop may add: pictures and a file where this Mac takes them.
    private var dropImages: Binding<[CompanionImage]>? { client.can(CompanionFeature.images) ? $images : nil }
    private var dropFiles: Binding<[CompanionFile]>? { client.can(CompanionFeature.attachments) ? $files : nil }

    /// Under the conversation, at the reading width: the working control, then what waits on you or the composer.
    private func dock(_ session: SessionDigest, _ scroll: ConversationScrollControl) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            // An agent in a terminal on the Mac keeps its conversation there; the phone only decides its approvals.
            // What waits on you, docked right above the composer, so it stays in
            // sight however far up you read; while it waits it takes the composer's place.
            if let item = session.items.first {
                if client.isOffline {
                    OfflineStrip(kind: .answers).appearsAfterDelay()
                        .padding(.horizontal, Theme.Spacing.lg)
                }
                PendingItemDock(session: session, item: item, more: session.items.count - 1,
                                onStop: canStop(session) ? { confirmStop = true } : nil)
            } else {
                // A message your Mac refused stays here with why, to edit and send again.
                ForEach(client.rejected.filter { $0.session == sessionID }) { refused in
                    RejectedMessageCard(message: refused) {
                        let back = client.takeRejected(refused)
                        message = back.text
                        images = back.images
                    } discard: {
                        _ = client.takeRejected(refused)
                    }
                }
                ComposerDock {
                    // What Nook could do next for this turn (another agent on a side task, a reminder), as on the Mac.
                    if let suggestion = client.shownSuggestion(session.suggestion) { SuggestionCard(suggestion: suggestion) }
                    composer(session, scroll).keepsDraft($message, for: .session(sessionID))
                }
            }
        }
        .readingColumn()
    }

    /// The composer under the conversation, or why there is none.
    @ViewBuilder
    private func composer(_ session: SessionDigest, _ scroll: ConversationScrollControl) -> some View {
        if !client.allows(.operate) {
            Label("Sending messages is turned off for this iPhone in Nook on your Mac.", systemImage: "lock.fill")
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                .card(padding: Theme.Spacing.lg)
        } else if session.canSend != false {
            // The Mac's composer: send, or stop while the agent works and nothing is typed. While it works and
            // the turn can take a message, a choice under the text says whether it steers now or waits.
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // The delegated tasks and side chats at work, a tap away, as the Mac's sub-thread strip.
                LineageStrip(session: session)
                ImageTray(images: $images)
                FileTray(files: $files)
                // What waits in line for after this turn, each with a way out (`CompanionFeature.agentsTab`), in a tray
                // tucked against the top of the box, as the Mac's composer shows its queue.
                VStack(spacing: 0) {
                    if let queued = session.queued, !queued.isEmpty {
                        ComposerTray(edge: .top) { QueuedMessagesStrip(session: session) }
                    } else if let next = session.nextPrompt, !next.isEmpty, message.isEmpty, dismissedPrompt != next {
                        // The Mac's suggested next message, a tap away: it lands in the field to read before it goes.
                        ComposerTray(edge: .top) {
                            NextPromptLine(text: next) {
                                withAnimation(Theme.reveal) { message = next }
                                composerFocused = true
                            } dismiss: {
                                withAnimation(Theme.reveal) { dismissedPrompt = next }
                            }
                        }
                    }
                    sessionComposer(session, scroll).zIndex(1)
                }
            }
        } else {
            Label("This agent runs in a terminal on your Mac; answer it there.", systemImage: "terminal")
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                .card(padding: Theme.Spacing.lg)
        }
    }

    /// The box itself: the "+" for pictures and a file inside it, as in a chat and on the Mac, then the Mac composer's
    /// choices for the turn (steer, mode, effort, model) in a row under the text.
    @ViewBuilder
    private func sessionComposer(_ session: SessionDigest, _ scroll: ConversationScrollControl) -> some View {
        let photos = client.can(CompanionFeature.images)
        let attachFiles = client.can(CompanionFeature.agentsTab) && client.can(CompanionFeature.attachments)
        // The Mac composer's mode, effort and model as one quiet choice (`agentsTab`), or only its model menu from a
        // Mac that has just that.
        let controls = SessionControlsMenu.shows(session, client: client)
        let models = controls ? nil : sessionModels(session)
        let steer = steerable(session)
        if photos || attachFiles || steer || controls || models != nil {
            SessionComposer(text: $message,
                            prompt: !steer ? "Message to the agent"
                                : steerByDefault ? "Steer the agent" : "Message for after this turn",
                            canSend: true, allowsEmpty: !images.isEmpty || !files.isEmpty, busy: stoppable(session),
                            onStop: canStop(session) ? { confirmStop = true } : nil,
                            focus: $composerFocused,
                            onSend: { send(session, scroll) }) {
                if photos || attachFiles {
                    InboxAttachButton(attachments: attachments, photos: photos, files: attachFiles,
                                      tooLargeNote: "A file from the phone can be at most 150 KB.")
                }
                if steer { steerMenu }
                if controls {
                    if steer { ComposerDivider() }
                    SessionControlsMenu(session: session)
                } else if let models {
                    modelMenu(session, models)
                }
            }
        } else {
            SessionComposer(text: $message, prompt: "Message to the agent", busy: stoppable(session),
                            onStop: canStop(session) ? { confirmStop = true } : nil,
                            focus: $composerFocused) { send(session, scroll) }
        }
    }

    /// The pictures and the file of the next message as one value, for the shared "+" (`InboxAttachButton`).
    private var attachments: Binding<InboxAttachments> {
        Binding(get: { InboxAttachments(images: images, files: files) },
                set: { images = $0.images; files = $0.files })
    }

    /// The messages that hold the words you look for, yours and the agent's answers, oldest first.
    private var matches: [String] {
        let words = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2 else { return [] }
        return entries.filter { ($0.kind == .user || $0.kind == .assistant) && (client.fullTexts[$0.id] ?? $0.text).localizedStandardContains(words) }
            .map(\.id)
    }

    private var currentMatch: String? {
        let all = matches
        return all.indices.contains(findIndex) ? all[findIndex] : all.last
    }

    /// "Claude Code · nook · main": the agent, its folder and its branch.
    static func subtitle(_ session: SessionDigest) -> String {
        [session.agent, session.folder, session.branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The page before the oldest message, keeping in sight what you were reading.
    private func loadEarlier(_ scroll: ConversationScrollControl) {
        guard !loadingEarlier, let first = entries.first?.id else { return }
        loadingEarlier = true
        Task {
            let more = await client.loadEarlier(sessionID)
            loadingEarlier = false
            guard more, let session else { return }
            let rows = TranscriptRow.rows(entries, working: session.attention == "working")
            if let row = rows.first(where: { $0.holds(first) }) { scroll.scrollTo(row.id, anchor: .top) }
        }
    }

    /// Sends the message: into the running turn when steering is chosen and possible, else as the Mac decides (now when
    /// the agent rests, after the turn while it works).
    private func send(_ session: SessionDigest, _ scroll: ConversationScrollControl) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty || !files.isEmpty else { return }
        let pictures = images
        let attached = files
        message = ""
        images = []
        files = []
        Haptics.tap()
        // What you sent is at the end: that is where you want to be.
        scroll.scrollToEnd()
        let steer = steerable(session) && steerByDefault
        Task { await client.send(session, text: text, steer: steer, images: pictures, files: attached) }
    }

    /// The agent works and its turn can take a message now (a Mac that says so, `CompanionFeature.steer`).
    private func steerable(_ session: SessionDigest) -> Bool {
        client.can(CompanionFeature.steer) && session.canSteer == true && session.attention == "working"
    }

    /// "Steer now" or "After this turn", as a quiet choice under the text, as the Mac's composer offers it.
    private var steerMenu: some View {
        ComposerDropdown(title: "While the agent works") {
            ComposerPill(symbol: steerByDefault ? "arrow.turn.down.right" : "list.bullet",
                         text: steerByDefault ? String(localized: "Steer now") : String(localized: "After this turn"))
        } content: {
            DropdownRow(symbol: "arrow.turn.down.right", title: String(localized: "Steer now"), chosen: steerByDefault) {
                steerByDefault = true
            }
            DropdownRow(symbol: "list.bullet", title: String(localized: "After this turn"), chosen: !steerByDefault) {
                steerByDefault = false
            }
        }
        .accessibilityLabel("While the agent works")
    }

    /// The models the session's agent can switch to, as the Mac's composer offers them; nil when there is no choice
    /// (an older Mac, an agent outside Nook, an agent with one model).
    private func sessionModels(_ session: SessionDigest) -> [LaunchOptions.Model]? {
        guard actions(session).contains(.model), let agent = session.agentID,
              let models = client.launchOptions?.agents.first(where: { $0.id == agent })?.models, models.count > 1 else { return nil }
        return models
    }

    /// The model, as the Mac's composer menu: another one runs from the next turn, in the same conversation.
    private func modelMenu(_ session: SessionDigest, _ models: [LaunchOptions.Model]) -> some View {
        let chosen = session.modelChoice ?? ""
        return ComposerDropdown(title: "Model") {
            ComposerPill(symbol: "cpu", text: models.first { $0.id == chosen }?.name ?? session.model ?? models.first?.name ?? "")
        } content: {
            ForEach(models) { option in
                DropdownRow(title: option.name, chosen: chosen == option.id) { manage(session, .model, text: option.id) }
            }
        }
        .disabled(client.isOffline)
        .accessibilityLabel("Model")
    }

    /// The buttons on the right of the bar: the changes, and the files, terminals and pull requests menu.
    private var trailingButtons: Int {
        (client.can(CompanionFeature.diff) ? 1 : 0)
            + (client.can(CompanionFeature.workspace) || client.can(CompanionFeature.pullRequests) ? 1 : 0)
    }

    private func stoppable(_ session: SessionDigest) -> Bool {
        ["working", "approval", "input"].contains(session.attention)
    }

    /// Stopping is for sessions Nook runs; one outside Nook ends instead (`SessionAction.end`).
    private func canStop(_ session: SessionDigest) -> Bool {
        client.allows(.operate) && session.canSend != false && !actions(session).contains(.end)
    }

    private func actions(_ session: SessionDigest) -> [SessionAction] {
        guard client.can(CompanionFeature.manage) else { return [] }
        return (session.actions ?? []).compactMap(SessionAction.init(rawValue:))
    }

    private func manage(_ session: SessionDigest, _ action: SessionAction, text: String? = nil) {
        Haptics.tap()
        Task { await client.manage(session, action, text: text) }
    }

    /// What you can do with the session from afar, as the Mac's row actions: stop or end it, snooze it, rename it, archive it.
    private func hasActions(_ session: SessionDigest) -> Bool {
        !actions(session).isEmpty || (canStop(session) && stoppable(session)) || session.lineage?.isEmpty == false
    }

    private func manageMenu<MenuLabel: View>(_ session: SessionDigest, @ViewBuilder label: () -> MenuLabel) -> some View {
        let actions = actions(session)
        return Menu {
            if client.can(CompanionFeature.timeline), !entries.isEmpty {
                Button {
                    withAnimation(Theme.reveal) { finding = true }
                } label: { Label("Find in conversation", systemImage: "magnifyingglass") }
            }
            if canStop(session), stoppable(session) {
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.circle") }
            }
            // The Mac's header menu, in its order (`SessionMenu.header`), on a Mac with the Agents tab.
            if client.can(CompanionFeature.agentsTab) {
                SessionActionsMenu(session: session, place: .header)
            } else {
                legacyActions(session, actions)
            }
        } label: {
            label()
        }
        .accessibilityHint("Shows what you can do with this session")
    }

    /// The menu of a Mac without the Agents tab: stop or end, snooze, main thread, rename, archive.
    @ViewBuilder
    private func legacyActions(_ session: SessionDigest, _ actions: [SessionAction]) -> some View {
        if actions.contains(.end) {
            Button(role: .destructive) { confirmEnd = true } label: { Label("End session", systemImage: "xmark.circle") }
        }
        if actions.contains(.unsnooze) {
            Button { manage(session, .unsnooze) } label: { Label("Cancel snooze", systemImage: "alarm") }
        } else if actions.contains(.snoozeHour) {
            Menu {
                Button("One hour") { manage(session, .snoozeHour) }
                Button("This evening") { manage(session, .snoozeEvening) }
                Button("Tomorrow morning") { manage(session, .snoozeTomorrow) }
                SnoozeCustomItems(session: session, actions: actions) { manage(session, $0) }
            } label: { Label("Snooze", systemImage: "clock") }
        }
        if actions.contains(.mainThreadOn) {
            Button { manage(session, .mainThreadOn) } label: { Label("Make main thread", systemImage: "arrow.triangle.branch") }
        } else if actions.contains(.mainThreadOff) {
            Button { manage(session, .mainThreadOff) } label: { Label("Stop main thread", systemImage: "arrow.triangle.branch") }
        }
        if actions.contains(.rename) {
            Button { newName = session.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
        }
        if actions.contains(.archive) {
            Button(role: .destructive) { confirmArchive = true } label: { Label("Archive", systemImage: "archivebox") }
        }
    }
}

/// The Mac's session header for the phone's bar: the folder as a quiet crumb, then the title, with a chevron when it
/// opens the session's actions; the agent and branch under it.
private struct SessionHeaderTitle: View {
    let session: SessionDigest
    let opens: Bool
    var maxWidth: CGFloat = widest

    /// The most the title takes, on an iPad too.
    static let widest: CGFloat = 260
    /// Room per bar button (a glass button and its share of the capsule), and from a button to the screen's edge and to the title.
    private static let button: CGFloat = 48
    private static let margins: CGFloat = 24

    /// How wide the title may be: centered in the bar, so as wide as the screen less the busier side on both sides, so it
    /// never runs under the back button or the buttons on the right.
    static func width(bar: CGFloat, buttons: Int) -> CGFloat {
        guard bar > 0 else { return widest }
        let side = margins + button * CGFloat(max(buttons, 1))
        return max(96, min(widest, bar - 2 * side))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.xs) {
                if !session.folder.isEmpty {
                    // The folder stays whole (it is short); the title gives way.
                    Text(verbatim: session.folder + " /").foregroundStyle(Theme.textTertiary).fixedSize()
                }
                Text(verbatim: session.title).foregroundStyle(Theme.paper)
                if opens {
                    Image(icon: "chevron.down").font(Theme.font(10, .bold)).foregroundStyle(Theme.textTertiary)
                }
            }
            .font(Theme.TextStyle.strong)
            .lineLimit(1)
            let detail = [session.agent, session.branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(verbatim: detail).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: maxWidth)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// "Earlier messages" at the top of a conversation the Mac sent only the end of: the page before it.
private struct EarlierMessagesButton: View {
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(icon: "arrow.up")
                }
                Text("Earlier messages")
            }
            .font(Theme.TextStyle.label)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 32)
            .roundedBackground(Theme.smoke, radius: Theme.Radius.control)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .disabled(loading)
        .padding(.top, Theme.Spacing.md)
    }
}

/// A message your Mac refused: why, what you wrote, and Edit to put it back in the composer (with its pictures) or
/// Discard.
private struct RejectedMessageCard: View {
    let message: RejectedMessage
    let edit: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label {
                Text("Not sent").foregroundStyle(Theme.paper)
            } icon: {
                Image(icon: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
            }
            .font(Theme.TextStyle.label)
            Text(verbatim: message.reason).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
            if !message.text.isEmpty {
                Text(verbatim: message.text).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(3)
            }
            HStack(spacing: Theme.Spacing.md) {
                NookPrimaryButton(title: String(localized: "Edit and send again"), action: edit)
                NookGhostButton(title: String(localized: "Discard"), action: discard)
            }
        }
        .card(tint: Theme.coral)
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

/// The first thing that waits on you, docked over the end of the conversation: the card itself, in a short scroll of its
/// own when it is tall, and how many more wait after it.
private struct PendingItemDock: View {
    let session: SessionDigest
    let item: SessionDigest.Item
    let more: Int
    /// Stops the session, as the Mac keeps Stop beside its question and approval card; nil where it cannot be stopped.
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView {
                ItemView(session: session, item: item)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.md) {
                if more > 0 {
                    Text("\(more) more wait after this one")
                        .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
                if let onStop {
                    Button {
                        Haptics.tap()
                        onStop()
                    } label: {
                        Label("Stop session", systemImage: "stop.fill")
                            .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                            .frame(minHeight: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(PressFade())
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// What waits on you in a session: an approval with Deny/Allow, or a question with its options and your own answer.
struct ItemView: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let item: SessionDigest.Item
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // An approval card: a small capitalized heading in the waiting color, then what is asked, large.
            Label {
                Text(heading).textCase(.uppercase).tracking(1.1)
            } icon: {
                Image(icon: item.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill")
            }
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.amber)
            if let header = item.questions?.first?.header, !header.isEmpty, item.kind == .question {
                Text(verbatim: header).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
            }
            // A short ask reads large; a long one (a plan to approve) reads as the Mac shows it, in blocks.
            if Self.isLong(item.title) {
                MarkdownBlocksView(text: item.title, color: Theme.paper)
            } else {
                Text(item.title).font(Theme.TextStyle.title).foregroundStyle(Theme.paper).textSelection(.enabled)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(Theme.TextStyle.code).foregroundStyle(Theme.textSecondary)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .roundedBackground(Theme.well, radius: Theme.Radius.control)
            }
            switch item.kind {
            case _ where !client.allows(.approve):
                ApproveOffLabel()
            case .approval:
                // Two large buttons across the card, easy to hit with a thumb: Deny, and Allow in Nook's color.
                HStack(spacing: Theme.Spacing.md) {
                    DecisionButton(title: String(localized: "Deny"), symbol: "xmark", role: .deny) {
                        Haptics.warning(); Task { await client.decide(session, item: item, allow: false) }
                    }
                    if item.canAllow {
                        DecisionButton(title: String(localized: "Allow"), symbol: "checkmark", role: .allow) {
                            Haptics.success(); Task { await client.decide(session, item: item, allow: true) }
                        }
                    }
                }
                // "Always allow" where the agent can remember it, as the Mac's third button (`CompanionFeature.agentsTab`).
                if item.canAllow, item.canAlways == true, client.can(CompanionFeature.agentsTab) {
                    Button {
                        Haptics.success(); Task { await client.decide(session, item: item, allow: true, always: true) }
                    } label: {
                        Label("Always allow", systemImage: "checkmark.seal")
                            .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .roundedBackground(Theme.smoke, radius: Theme.Radius.control)
                    }
                    .buttonStyle(PressFade())
                }
                if !item.canAllow {
                    Label("This is risky or unknown: it can only be allowed on your Mac.", systemImage: "lock.fill")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                }
                // What you type denies it and tells the agent why, or what to do instead.
                SessionComposer(text: $text, prompt: "Or deny with a reason") {
                    let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    text = ""
                    Haptics.warning()
                    Task { await client.decide(session, item: item, allow: false, reason: reason) }
                }
            case .question:
                // Several questions, or several answers to one: one at a time, as the Mac's card (`agentsTab`).
                if client.can(CompanionFeature.agentsTab), let questions = item.questions, !questions.isEmpty,
                   questions.count > 1 || questions[0].multiSelect {
                    QuestionFlow(session: session, item: item, questions: questions)
                } else if item.canAllow {
                    VStack(spacing: Theme.Spacing.sm) {
                        ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                            QuestionOptionRow(title: option, number: number) {
                                Haptics.success(); Task { await client.answer(session, item: item, text: option) }
                            }
                            // What the option would look like, under it (an agent question's preview), as on the Mac.
                            if let previews = item.optionPreviews, previews.indices.contains(number) {
                                QuestionOptionPreview(text: previews[number], indent: Theme.Spacing.lg, lineLimit: 10)
                            }
                        }
                    }
                    // Your own words only where the question takes them (`SessionQuestion.allowsOther`), or when it has
                    // no options at all; an older Mac does not say, so it keeps the field.
                    if item.options.isEmpty || item.questions?.first?.allowsOther != false {
                        SessionComposer(text: $text, prompt: "Your own answer") {
                            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            text = ""
                            Haptics.success()
                            Task { await client.answer(session, item: item, text: answer) }
                        }
                    }
                } else {
                    Label("Several questions at once: answer them on your Mac.", systemImage: "laptopcomputer")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                }
            }
        }
        .card(tint: Theme.amber)
    }

    /// A plan or another ask of several lines: read as blocks instead of one large title.
    static func isLong(_ text: String) -> Bool {
        text.count > 160 || text.contains("\n")
    }

    /// Typed, so both words go through the String Catalog.
    private var heading: LocalizedStringKey { item.kind == .approval ? "Approval needed" : "Waiting for your answer" }
}

/// A full-width round button of an approval: Allow on Nook's own color, Deny on the surface with its word in coral.
struct DecisionButton: View {
    enum Role { case allow, deny }

    let title: String
    let symbol: String
    let role: Role
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(icon: symbol).font(Theme.font(13, .bold))
                Text(title).font(Theme.textFont(15, .semibold))
            }
            .foregroundStyle(role == .allow ? Theme.onIris : Theme.coral)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Capsule().fill(role == .allow ? Theme.iris : Theme.coral.opacity(0.12)))
            .overlay(Capsule().strokeBorder(role == .allow ? Color.clear : Theme.coral.opacity(0.3), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
    }
}

/// In place of Allow, Deny or an answer when the Mac does not let this phone approve (`CompanionScope.approve`).
struct ApproveOffLabel: View {
    var body: some View {
        Label("Approving is turned off for this iPhone in Nook on your Mac.", systemImage: "lock.fill")
            .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
    }
}

// MARK: Starting a session

/// A new session on the Mac, as the Mac's `NewSessionComposer`: one question ("What should we build in Nook?", the
/// project a menu in it), one composer with the agent and plan mode as quiet choices under the text, and where it works
/// in a tray tucked under the box. Account, model and permissions come from the Mac's own defaults for that agent, and
/// "allow everything" is never used for a session started here.
struct NewSessionView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    /// A `nook://prompt` link this sheet was opened for: its text, and the project and agent it names.
    var link: PromptLink? = nil
    /// The project folder to start in (a project's "+" in the Agents list); nil for the link's or your defaults.
    var startIn: String? = nil
    let started: (String) -> Void

    @State private var task = ""
    @State private var agent = ""
    @State private var project = ""
    @State private var plan = false
    @State private var mainThread = false
    @State private var worktree = false
    /// The model id for the chosen agent ("" is the agent's own default), from the Mac's composer menu.
    @State private var model = ""
    /// Pictures that go with the task.
    @State private var images: [CompanionImage] = []
    /// A file that goes with the task (`CompanionFeature.attachments`).
    @State private var files: [CompanionFile] = []
    /// The Agents tab's choices (`CompanionFeature.agentsTab`): a name of your own, the reasoning effort ("" the agent's
    /// default), the access (never more than "allow edits"), and the branch a new worktree starts from.
    @State private var title = ""
    /// The pictures and the file the session starts with as one value, for the shared "+" (`InboxAttachButton`).
    private var attachments: Binding<InboxAttachments> {
        Binding(get: { InboxAttachments(images: images, files: files) },
                set: { images = $0.images; files = $0.files })
    }
    @State private var effort = ""
    @State private var permission = ""
    @State private var baseBranch = ""
    @State private var loaded = false
    @State private var prepared = false
    @State private var starting = false
    /// Why the last start did not work; shown in the sheet, where the app's alert cannot appear.
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var options: LaunchOptions? { client.launchOptions }
    private var chosenAgent: LaunchOptions.Agent? { options?.agents.first { $0.id == agent } }
    private var chosenProject: LaunchOptions.Project? { options?.projects.first { $0.path == project } }
    private var canStart: Bool {
        !starting && chosenAgent != nil && chosenProject != nil && !(client.isOffline && !client.writingWaits)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    content(options)
                        // A picture, a link or text dragged onto the sheet goes into the task.
                        .composerDrop(text: $task, images: client.can(CompanionFeature.images) ? $images : nil)
                } else if loaded {
                    WSEmptyState(symbol: "wifi.slash", title: String(localized: "Your Mac does not answer."),
                               message: String(localized: "Is the companion on, and are you on the same Wi‑Fi?"))
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .screen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Theme.paper) }
            }
            .onAppear(perform: prepare)
            .task {
                await client.loadLaunchOptions()
                loaded = true
                prepare()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.paper)
    }

    @ViewBuilder
    private func content(_ options: LaunchOptions) -> some View {
        if options.agents.isEmpty {
            WSEmptyState(symbol: "person.crop.circle.badge.questionmark", title: String(localized: "No agent is ready on your Mac."),
                       message: String(localized: "Connect one in Nook › Settings › Agents."))
        } else if options.projects.isEmpty {
            WSEmptyState(symbol: "folder", title: String(localized: "No folders yet."),
                       message: String(localized: "Start a session on your Mac once: its folder then shows up here."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    NookMark(size: 44)
                    heading(options)
                    if client.isOffline {
                        Banner(text: client.writingWaits
                               ? String(localized: "Offline: the session does not start yet. It waits on this iPhone and starts as soon as your Mac is back.")
                               : String(localized: "Offline: connect to your Mac to start a session."),
                               symbol: "wifi.slash")
                            .appearsAfterDelay()
                    }
                    if client.can(CompanionFeature.agentsTab) {
                        TextField("Name (optional)", text: $title)
                            .font(Theme.TextStyle.body).foregroundStyle(Theme.paper)
                            .padding(.horizontal, Theme.Spacing.lg).frame(minHeight: 44)
                            .roundedBackground(Theme.field, radius: Theme.Radius.control)
                    }
                    ImageTray(images: $images)
                    FileTray(files: $files)
                    VStack(spacing: 0) {
                        SessionComposer(text: $task, prompt: "What should the agent do?", minHeight: 88, lines: 4...10,
                                        canSend: canStart, sending: starting, focus: $focused, onSend: start) {
                            agentMenu(options)
                            if let models = chosenAgent?.models, models.count > 1 {
                                ComposerDivider()
                                modelMenu(models)
                            }
                            // Pictures and a file behind one "+", as in a session and a chat.
                            let attachFiles = client.can(CompanionFeature.agentsTab) && client.can(CompanionFeature.attachments)
                            if client.can(CompanionFeature.images) || attachFiles {
                                ComposerDivider()
                                InboxAttachButton(attachments: attachments, photos: client.can(CompanionFeature.images),
                                                  files: attachFiles, tooLargeNote: "A file from the phone can be at most 150 KB.")
                            }
                            if let agent = chosenAgent, (agent.efforts?.count ?? 0) > 1 || (agent.permissions?.count ?? 0) > 1 {
                                ComposerDivider()
                                choicesMenu(agent)
                            }
                            if chosenAgent?.canPlan == true {
                                ComposerDivider()
                                Button { withAnimation(Theme.reveal) { plan.toggle() } } label: {
                                    ComposerPill(symbol: "list.bullet.clipboard", text: String(localized: "Plan first"),
                                                 tint: plan ? Theme.paper : nil, showsChevron: false)
                                        .roundedBackground(plan ? Theme.smoke : Color.clear, radius: Theme.Radius.control)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(plan ? .isSelected : [])
                            }
                            // The Mac composer's "Main thread": the agent hands its work to sub-threads that report back.
                            if chosenAgent?.canMainThread == true {
                                ComposerDivider()
                                Button { withAnimation(Theme.reveal) { mainThread.toggle() } } label: {
                                    ComposerPill(symbol: "arrow.triangle.branch", text: String(localized: "Main thread"),
                                                 tint: mainThread ? Theme.paper : nil, showsChevron: false)
                                        .roundedBackground(mainThread ? Theme.smoke : Color.clear, radius: Theme.Radius.control)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(mainThread ? .isSelected : [])
                                .accessibilityHint("The agent hands its work to sub-threads that report back here.")
                            }
                        }
                        .keepsDraft($task, for: .newSession)
                        .zIndex(1)
                        ComposerTray(edge: .bottom) { whereRow }
                    }
                    Label("Anything risky still waits for your approval.",
                          systemImage: "lock.shield")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Spacing.xs)
                    if let failure {
                        Banner(text: failure, symbol: "exclamationmark.triangle.fill", color: Theme.coral)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// "What should we build in Nook?": the project is the menu, underlined with dots as on the Mac.
    private func heading(_ options: LaunchOptions) -> some View {
        ComposerDropdown(title: "Folder") {
            (Text("What should we build in ").foregroundStyle(Theme.paper)
             + Text(verbatim: chosenProject?.name ?? "…").foregroundStyle(Theme.paper).underline(true, pattern: .dot, color: Theme.textTertiary)
             + Text(verbatim: "?").foregroundStyle(Theme.paper))
                .font(Theme.TextStyle.display)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } content: {
            ForEach(options.projects) { option in
                DropdownRow(symbol: "folder", title: option.name, detail: Self.tilde(option.path), chosen: project == option.path) {
                    withAnimation(Theme.reveal) { project = option.path; baseBranch = option.defaultBase ?? "" }
                }
            }
        }
    }

    /// The model, as the Mac's composer offers it for this agent ("Default" is the agent's own choice).
    private func modelMenu(_ models: [LaunchOptions.Model]) -> some View {
        ComposerDropdown(title: "Model") {
            ComposerPill(symbol: "cpu", text: models.first { $0.id == model }?.name ?? models.first?.name ?? "")
        } content: {
            ForEach(models) { option in
                DropdownRow(title: option.name, chosen: model == option.id) { withAnimation(Theme.reveal) { model = option.id } }
            }
        }
        .accessibilityLabel("Model")
    }

    /// The agent, with its logo, as a menu in the composer.
    private func agentMenu(_ options: LaunchOptions) -> some View {
        ComposerDropdown(title: "Agent") {
            ComposerPill(agent: chosenAgent?.name ?? agent, text: chosenAgent?.name ?? "")
        } content: {
            ForEach(options.agents) { option in
                DropdownRow(agent: option.name, title: option.name, chosen: agent == option.id) {
                    withAnimation(Theme.reveal) {
                        agent = option.id
                        // Another agent starts on its own default model, effort and access.
                        model = option.defaultModel ?? ""
                        effort = option.defaultEffort ?? ""
                        permission = option.defaultPermission ?? ""
                    }
                }
            }
        }
    }

    /// Effort and access for the new session, as the Mac composer's picker offers them; access never above "allow edits".
    private func choicesMenu(_ agent: LaunchOptions.Agent) -> some View {
        ComposerDropdown(title: "Effort and access") {
            ComposerPill(symbol: "slider.horizontal.3", text: choicesSummary(agent))
        } content: {
            if let efforts = agent.efforts, efforts.count > 1 {
                DropdownHeader(title: "Effort")
                ForEach(efforts) { level in
                    DropdownRow(title: level.name, chosen: effort == level.id) { effort = level.id }
                }
            }
            if let permissions = agent.permissions, permissions.count > 1, !plan {
                if (agent.efforts?.count ?? 0) > 1 { DropdownDivider() }
                DropdownHeader(title: "Access")
                ForEach(permissions) { level in
                    DropdownRow(title: level.name, chosen: permission == level.id) { permission = level.id }
                }
            }
        }
        .accessibilityLabel("Effort and access")
    }

    /// "High · Allow edits": the effort (when not the default) and the access.
    private func choicesSummary(_ agent: LaunchOptions.Agent) -> String {
        let parts = [effort.isEmpty ? nil : agent.efforts?.first { $0.id == effort }?.name,
                     agent.permissions?.first { $0.id == permission }?.name].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Options") : parts.joined(separator: " · ")
    }

    /// The branch a new worktree starts from, as the Mac's composer offers it.
    @ViewBuilder
    private var baseMenu: some View {
        if worktree, let branches = chosenProject?.branches, branches.count > 1 {
            let chosen = baseBranch.isEmpty ? (chosenProject?.defaultBase ?? "") : baseBranch
            ComposerDropdown(title: "Base branch") {
                ComposerPill(symbol: "arrow.triangle.branch", text: chosen)
            } content: {
                ForEach(branches, id: \.self) { branch in
                    DropdownRow(symbol: "arrow.triangle.branch", title: branch, chosen: chosen == branch) { baseBranch = branch }
                }
            }
            .accessibilityLabel("Base branch")
        }
    }

    /// Where it works, in the tray under the box: the folder as it is or a new worktree, and the folder's place.
    private var whereRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if chosenProject?.canWorktree == true {
                ComposerDropdown {
                    ComposerPill(symbol: worktree ? "square.stack.3d.up" : "folder",
                                 text: worktree ? String(localized: "New worktree") : String(localized: "Current checkout"))
                } content: {
                    DropdownRow(symbol: "folder", title: String(localized: "Current checkout"), chosen: !worktree) { worktree = false }
                    DropdownRow(symbol: "square.stack.3d.up", title: String(localized: "New worktree"), chosen: worktree) { worktree = true }
                }
            } else {
                ComposerPill(symbol: "folder", text: String(localized: "Current checkout"), showsChevron: false)
            }
            baseMenu
            Spacer(minLength: Theme.Spacing.md)
            if let chosenProject {
                Text(Self.tilde(chosenProject.path)).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.leading, -Theme.Spacing.md)
    }

    /// Your defaults from the Mac, once.
    private func prepare() {
        guard !prepared, let options else { return }
        prepared = true
        agent = link?.agent(in: options.agents)?.id ?? options.defaultAgent ?? options.agents.first?.id ?? ""
        project = startIn.flatMap { folder in options.projects.first { $0.path == folder }?.path }
            ?? link?.project(in: options.projects)?.path ?? options.defaultProject ?? options.projects.first?.path ?? ""
        plan = options.defaultPlan
        worktree = options.defaultWorktree
        baseBranch = options.projects.first { $0.path == project }?.defaultBase ?? ""
        model = options.agents.first { $0.id == agent }?.defaultModel ?? ""
        effort = options.agents.first { $0.id == agent }?.defaultEffort ?? ""
        permission = options.agents.first { $0.id == agent }?.defaultPermission ?? ""
        // A link only fills in the task; you read it and start the session yourself.
        if let link, task.isEmpty { task = link.text }
        focused = true
    }

    private func start() {
        guard canStart, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        starting = true
        failure = nil
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var launch = LaunchRequest(agent: agent, project: project, task: task, title: name.isEmpty ? nil : name,
                                   plan: plan && chosenAgent?.canPlan == true,
                                   worktree: worktree && chosenProject?.canWorktree == true,
                                   model: chosenAgent?.models == nil ? nil : model,
                                   mainThread: mainThread && chosenAgent?.canMainThread == true ? true : nil)
        // The Agents tab's choices, only where the Mac offers them (an older Mac keeps its defaults).
        if client.can(CompanionFeature.agentsTab), let chosen = chosenAgent {
            if chosen.efforts != nil { launch.effort = effort }
            if chosen.permissions != nil, !permission.isEmpty { launch.permission = permission }
            if launch.worktree, chosenProject?.branches?.contains(baseBranch) == true { launch.baseBranch = baseBranch }
        }
        let pictures = images
        let attached = files
        Task {
            let delivery = await client.start(launch, images: pictures, files: attached)
            starting = false
            switch delivery {
            case .sent(let response):
                Haptics.success()
                PhoneDrafts().set("", for: .newSession)
                dismiss()
                if let id = response.created { started(id) }
            case .waiting:
                // Kept on the phone: the Agents list shows it as waiting for your Mac, and it starts once the Mac answers.
                Haptics.success()
                PhoneDrafts().set("", for: .newSession)
                dismiss()
            case .refused:
                Haptics.warning()
                failure = client.notice ?? String(localized: "Your Mac refused this.")
                client.notice = nil
            }
        }
    }

    /// `/Users/name/code/app` as `~/code/app`: the folder's place without the long prefix.
    private static func tilde(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return path }
        return "~/" + parts.dropFirst(2).joined(separator: "/")
    }
}

/// One answer to an agent's question, the Mac's option row in a question card: its number on a small key, the answer,
/// on `field` with a faint edge.
struct QuestionOptionRow: View {
    let title: String
    let number: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Text(number < 9 ? "\(number + 1)" : "·")
                    .font(Theme.textFont(11, .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: 22, minHeight: 22)
                    .roundedBackground(Theme.well, radius: Theme.Radius.chip)
                Text(title)
                    .font(Theme.textFont(13, .semibold))
                    .foregroundStyle(Theme.paper)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.xs)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground(Theme.field, stroke: Theme.paper.opacity(0.08), radius: Theme.Radius.card)
            .roundedHitShape(Theme.Radius.card)
        }
        .buttonStyle(PressFade())
    }
}
