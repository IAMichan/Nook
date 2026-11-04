import SwiftUI

// MARK: One session

/// A session as a conversation: a header with where it works, the messages, the agent's steps folded into groups,
/// what waits on you, and a field to reply.
struct SessionDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var message = ""
    @State private var confirmStop = false
    @State private var confirmArchive = false
    @State private var confirmEnd = false
    @State private var renaming = false
    @State private var newName = ""
    /// Whether the newest message is in sight; scrolled up, an arrow brings you back.
    @State private var atEnd = true
    /// While the agent works, what a message does: steer the running turn now, or wait in line for after it. Remembered,
    /// as the Mac's "While the agent works" setting.
    @AppStorage("nook.companion.steerByDefault") private var steerByDefault = false
    /// Pictures that go with the next message.
    @State private var images: [CompanionImage] = []
    /// The session's changes are open (`SessionChangesView`).
    @State private var reviewing = false

    private var session: SessionDigest? { client.sessions.first { $0.id == sessionID } }
    private var entries: [TimelineEntry] { client.timelines[sessionID] ?? [] }

    var body: some View {
        if let session {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        SessionHeader(session: session, review: client.can(CompanionFeature.diff) ? { reviewing = true } : nil)
                        if client.can(CompanionFeature.timeline), !entries.isEmpty {
                            TranscriptConversation(entries: entries, working: session.attention == "working")
                        } else if !session.excerpt.isEmpty {
                            SectionHeader(title: "Latest reply")
                            TranscriptReply(text: session.excerpt, footer: false)
                        }
                        // Messages that wait in the outbox until the Mac takes them.
                        let waiting = client.outbox.waiting(for: session.id)
                        ForEach(waiting) { entry in
                            TranscriptUserMessage(text: entry.request.text ?? "", pending: true)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.lg)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: entries.last?.id) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onChange(of: session.items.count) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .defaultScrollAnchor(.bottom)
                .modifier(ScrollEndTracker(atEnd: $atEnd))
                .safeAreaInset(edge: .bottom) {
                VStack(spacing: Theme.Spacing.md) {
                    FloatingWorkingControl(
                        workingSince: entries.last(where: { $0.kind == .user }).map { Date(timeIntervalSince1970: $0.date) },
                        working: session.attention == "working",
                        snoozed: actions(session).contains(.unsnooze),
                        onWake: { manage(session, .unsnooze) },
                        showScrollToEnd: !atEnd) {
                        withAnimation(Theme.reveal) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    }
                // An agent in a terminal on the Mac keeps its conversation there; the phone only decides its approvals.
                // What waits on you, docked right above the composer, so it stays in
                // sight however far up you read; while it waits it takes the composer's place.
                if let item = session.items.first {
                    PendingItemDock(session: session, item: item, more: session.items.count - 1)
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
                    if !client.allows(.operate) {
                        Label("Sending messages is turned off for this iPhone in Nook on your Mac.", systemImage: "lock.fill")
                            .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                            .card(padding: Theme.Spacing.lg)
                    } else if session.canSend != false {
                        // The Mac's composer: send, or stop while the agent works and nothing is typed. While it works and
                        // the turn can take a message, a choice under the text says whether it steers now or waits.
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            ImageTray(images: $images)
                            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                                // Pictures for the agent, as from the Mac's composer (a Mac that takes them).
                                if client.can(CompanionFeature.images) {
                                    AttachPictureButton(images: $images).padding(.bottom, Theme.Spacing.sm)
                                }
                                if steerable(session) {
                                    SessionComposer(text: $message, prompt: steerByDefault ? "Steer the agent" : "Message for after this turn",
                                                    canSend: true, busy: stoppable(session),
                                                    onStop: canStop(session) ? { confirmStop = true } : nil,
                                                    onSend: { send(session) }) {
                                        steerMenu
                                    }
                                } else {
                                    SessionComposer(text: $message, prompt: "Message to the agent", busy: stoppable(session),
                                                    onStop: canStop(session) ? { confirmStop = true } : nil) { send(session) }
                                }
                            }
                        }
                    } else {
                        Label("This agent runs in a terminal on your Mac; answer it there.", systemImage: "terminal")
                            .font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                            .card(padding: Theme.Spacing.lg)
                    }
                }
                }
                }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: session.title, subtitle: session.folder) }
                if !actions(session).isEmpty || (canStop(session) && stoppable(session)) {
                    ToolbarItem(placement: .topBarTrailing) { manageMenu(session) }
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
            .navigationDestination(isPresented: $reviewing) {
                // A comment on a line goes into this session's message, under what you wrote.
                SessionChangesView(sessionID: sessionID) { comment in
                    let intro = "Review comments on your changes. Address each one:"
                    let current = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    message = (current.isEmpty ? intro : current) + "\n\n" + comment
                }
            }
            // A push about this session arrives without a banner while it is on screen.
            .onAppear { client.visibleSession = sessionID }
            .onDisappear {
                if client.visibleSession == sessionID { client.visibleSession = nil }
                Task { await client.unwatchSession(sessionID) }
            }
            // While the session is on screen its conversation stays current: live from a Mac that sends it by itself
            // (`watchSession`), else asked for every few seconds. Leaving the screen ends the loop.
            .task {
                let live = await client.watchSession(sessionID)
                while !Task.isCancelled {
                    let following = live && client.timelineIsLive
                    if !following { await client.loadTimeline(sessionID) }
                    let working = client.sessions.first { $0.id == sessionID }?.attention == "working"
                    try? await Task.sleep(for: .seconds(following ? 30 : (working ? 2 : 5)))
                }
            }
        } else {
            EmptyState(symbol: "tray", title: "This session is gone.", message: "It was closed or archived on your Mac.") {}
                .screen()
        }
    }

    private static let bottom = "bottom"

    /// Sends the message: into the running turn when steering is chosen and possible, else as the Mac decides (now when
    /// the agent rests, after the turn while it works).
    private func send(_ session: SessionDigest) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        let pictures = images
        message = ""
        images = []
        Haptics.tap()
        let steer = steerable(session) && steerByDefault
        Task { await client.send(session, text: text, steer: steer, images: pictures) }
    }

    /// The agent works and its turn can take a message now (a Mac that says so, `CompanionFeature.steer`).
    private func steerable(_ session: SessionDigest) -> Bool {
        client.can(CompanionFeature.steer) && session.canSteer == true && session.attention == "working"
    }

    /// "Steer now" or "After this turn", as a quiet choice under the text, as the Mac's composer offers it.
    private var steerMenu: some View {
        Menu {
            Button { steerByDefault = true } label: {
                Label("Steer now", systemImage: steerByDefault ? "checkmark" : "arrow.turn.down.right")
            }
            Button { steerByDefault = false } label: {
                Label("After this turn", systemImage: steerByDefault ? "list.bullet" : "checkmark")
            }
        } label: {
            ComposerPill(symbol: steerByDefault ? "arrow.turn.down.right" : "list.bullet",
                         text: steerByDefault ? String(localized: "Steer now") : String(localized: "After this turn"))
        }
        .accessibilityLabel("While the agent works")
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
    private func manageMenu(_ session: SessionDigest) -> some View {
        let actions = actions(session)
        return Menu {
            if canStop(session), stoppable(session) {
                Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.circle") }
            }
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
                } label: { Label("Snooze", systemImage: "clock") }
            }
            if actions.contains(.rename) {
                Button { newName = session.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
            }
            if actions.contains(.archive) {
                Button(role: .destructive) { confirmArchive = true } label: { Label("Archive", systemImage: "archivebox") }
            }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(Theme.text)
        }
        .accessibilityLabel("More")
    }
}

/// Tells whether the end of a scroll view is in sight (iOS 18 and later; before, it counts as always in sight).
private struct ScrollEndTracker: ViewModifier {
    @Binding var atEnd: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height || geometry.visibleRect.maxY >= geometry.contentSize.height - 64
            } action: { _, now in
                atEnd = now
            }
        } else {
            content
        }
    }
}

/// Who works where, under the screen's title: the agent's logo and name, its status, and the folder and branch.
private struct SessionHeader: View {
    let session: SessionDigest
    /// Opens what the session changed; nil when this Mac cannot show it.
    var review: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                AgentLogo(agent: session.agent, size: 18)
                Text(session.agent).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: Theme.Spacing.md)
                StatusPill(attention: session.attention)
            }
            HStack(spacing: Theme.Spacing.lg) {
                MetaChip(symbol: "folder", text: session.folder)
                if let branch = session.branch, !branch.isEmpty { MetaChip(symbol: "arrow.triangle.branch", text: branch) }
                Spacer(minLength: 0)
                if let review {
                    Button(action: review) {
                        Label("Changes", systemImage: "plusminus")
                            .font(Theme.TextStyle.label)
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Theme.raised, in: Capsule())
                    }
                    .buttonStyle(PressFade())
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .padding(.top, Theme.Spacing.md)
    }
}

/// Where a session works, as a mark and a word: no fill, as the Mac's row badges.
private struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol).foregroundStyle(Theme.textTertiary)
            Text(text).foregroundStyle(Theme.textSecondary)
        }
        .font(Theme.TextStyle.label)
        .lineLimit(1)
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
                Text("Not sent").foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
            }
            .font(Theme.TextStyle.label)
            Text(verbatim: message.reason).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
            if !message.text.isEmpty {
                Text(verbatim: message.text).font(Theme.TextStyle.body).foregroundStyle(Theme.text).lineLimit(3)
            }
            HStack(spacing: Theme.Spacing.md) {
                Button("Edit and send again", action: edit).buttonStyle(ActionButtonStyle()).fixedSize()
                Button("Discard", role: .destructive, action: discard)
                    .font(Theme.TextStyle.label).foregroundStyle(Theme.coral)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView {
                ItemView(session: session, item: item)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            if more > 0 {
                Text("\(more) more wait after this one")
                    .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
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
            Label {
                Text(heading).foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: item.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill").foregroundStyle(Theme.amber)
            }
            .font(Theme.TextStyle.label)
            Text(item.title).font(Theme.TextStyle.body).foregroundStyle(Theme.text).textSelection(.enabled)
            if !item.detail.isEmpty {
                Text(item.detail).font(Theme.TextStyle.code).foregroundStyle(Theme.textSecondary)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            switch item.kind {
            case _ where !client.allows(.approve):
                ApproveOffLabel()
            case .approval:
                if item.canAllow {
                    NookSplitButton(primary: NoticeAction(label: "Allow", symbol: "checkmark") {
                        Haptics.success(); Task { await client.decide(session, item: item, allow: true) }
                    }, secondary: NoticeAction(label: "Deny") {
                        Haptics.warning(); Task { await client.decide(session, item: item, allow: false) }
                    })
                } else {
                    Button("Deny") { Haptics.warning(); Task { await client.decide(session, item: item, allow: false) } }
                        .buttonStyle(ActionButtonStyle(color: Theme.coral))
                        .fixedSize()
                }
                if !item.canAllow {
                    Label("This is risky or unknown: it can only be allowed on your Mac.", systemImage: "lock.fill")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                }
            case .question:
                if item.canAllow {
                    VStack(spacing: Theme.Spacing.md) {
                        ForEach(item.options, id: \.self) { option in
                            Button(option) { Haptics.success(); Task { await client.answer(session, item: item, text: option) } }
                                .buttonStyle(ActionButtonStyle())
                        }
                    }
                    SessionComposer(text: $text, prompt: "Your own answer") {
                        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        text = ""
                        Haptics.success()
                        Task { await client.answer(session, item: item, text: answer) }
                    }
                } else {
                    Label("Several questions at once: answer them on your Mac.", systemImage: "laptopcomputer")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                }
            }
        }
        .card(tint: Theme.amber)
    }

    /// Typed, so both words go through the String Catalog.
    private var heading: LocalizedStringKey { item.kind == .approval ? "Approval" : "Question" }
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
    let started: (String) -> Void

    @State private var task = ""
    @State private var agent = ""
    @State private var project = ""
    @State private var plan = false
    @State private var worktree = false
    /// The model id for the chosen agent ("" is the agent's own default), from the Mac's composer menu.
    @State private var model = ""
    /// Pictures that go with the task.
    @State private var images: [CompanionImage] = []
    @State private var loaded = false
    @State private var prepared = false
    @State private var starting = false
    /// Why the last start did not work; shown in the sheet, where the app's alert cannot appear.
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var options: LaunchOptions? { client.launchOptions }
    private var chosenAgent: LaunchOptions.Agent? { options?.agents.first { $0.id == agent } }
    private var chosenProject: LaunchOptions.Project? { options?.projects.first { $0.path == project } }
    private var canStart: Bool { !starting && chosenAgent != nil && chosenProject != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    content(options)
                } else if loaded {
                    EmptyState(symbol: "wifi.slash", title: "Your Mac does not answer.",
                               message: "Is the companion on, and are you on the same Wi‑Fi?") {}
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .screen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Theme.text) }
            }
            .onAppear(perform: prepare)
            .task {
                await client.loadLaunchOptions()
                loaded = true
                prepare()
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.text)
    }

    @ViewBuilder
    private func content(_ options: LaunchOptions) -> some View {
        if options.agents.isEmpty {
            EmptyState(symbol: "person.crop.circle.badge.questionmark", title: "No agent is ready on your Mac.",
                       message: "Connect one in Nook › Settings › Agents.") {}
        } else if options.projects.isEmpty {
            EmptyState(symbol: "folder", title: "No folders yet.",
                       message: "Start a session on your Mac once: its folder then shows up here.") {}
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    NookMark(size: 44)
                    heading(options)
                    ImageTray(images: $images)
                    VStack(spacing: 0) {
                        SessionComposer(text: $task, prompt: "What should the agent do?", minHeight: 88, lines: 4...10,
                                        canSend: canStart, sending: starting, focus: $focused, onSend: start) {
                            agentMenu(options)
                            if let models = chosenAgent?.models, models.count > 1 {
                                ComposerDivider()
                                modelMenu(models)
                            }
                            if client.can(CompanionFeature.images) {
                                ComposerDivider()
                                AttachPictureButton(images: $images)
                            }
                            if chosenAgent?.canPlan == true {
                                ComposerDivider()
                                Button { withAnimation(Theme.reveal) { plan.toggle() } } label: {
                                    ComposerPill(symbol: "list.bullet.clipboard", text: String(localized: "Plan first"),
                                                 tint: plan ? Theme.text : nil, showsChevron: false)
                                        .background(plan ? Theme.raised : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(plan ? .isSelected : [])
                            }
                        }
                        .zIndex(1)
                        ComposerTray(edge: .bottom) { whereRow }
                    }
                    Label("Nook uses your account, model and permissions for this agent. Anything risky still waits for your approval.",
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
        Menu {
            ForEach(options.projects) { option in
                Button { withAnimation(Theme.reveal) { project = option.path } } label: {
                    if project == option.path {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
            }
        } label: {
            (Text("What should we build in ").foregroundStyle(Theme.text)
             + Text(verbatim: chosenProject?.name ?? "…").foregroundStyle(Theme.text).underline(true, pattern: .dot, color: Theme.textTertiary)
             + Text(verbatim: "?").foregroundStyle(Theme.text))
                .font(Theme.TextStyle.display)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// The model, as the Mac's composer offers it for this agent ("Default" is the agent's own choice).
    private func modelMenu(_ models: [LaunchOptions.Model]) -> some View {
        Menu {
            ForEach(models) { option in
                Button { withAnimation(Theme.reveal) { model = option.id } } label: {
                    if model == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            ComposerPill(symbol: "cpu", text: models.first { $0.id == model }?.name ?? models.first?.name ?? "")
        }
        .accessibilityLabel("Model")
    }

    /// The agent, with its logo, as a menu in the composer.
    private func agentMenu(_ options: LaunchOptions) -> some View {
        Menu {
            ForEach(options.agents) { option in
                Button {
                    withAnimation(Theme.reveal) {
                        agent = option.id
                        // Another agent starts on its own default model.
                        model = option.defaultModel ?? ""
                    }
                } label: {
                    if agent == option.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
        } label: {
            ComposerPill(agent: chosenAgent?.name ?? agent, text: chosenAgent?.name ?? "")
        }
    }

    /// Where it works, in the tray under the box: the folder as it is or a new worktree, and the folder's place.
    private var whereRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if chosenProject?.canWorktree == true {
                Menu {
                    Button { worktree = false } label: {
                        if worktree { Text("Current checkout") } else { Label("Current checkout", systemImage: "checkmark") }
                    }
                    Button { worktree = true } label: {
                        if worktree { Label("New worktree", systemImage: "checkmark") } else { Text("New worktree") }
                    }
                } label: {
                    ComposerPill(symbol: worktree ? "square.stack.3d.up" : "folder",
                                 text: worktree ? String(localized: "New worktree") : String(localized: "Current checkout"))
                }
            } else {
                ComposerPill(symbol: "folder", text: String(localized: "Current checkout"), showsChevron: false)
            }
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
        project = link?.project(in: options.projects)?.path ?? options.defaultProject ?? options.projects.first?.path ?? ""
        plan = options.defaultPlan
        worktree = options.defaultWorktree
        model = options.agents.first { $0.id == agent }?.defaultModel ?? ""
        // A link only fills in the task; you read it and start the session yourself.
        if let link, task.isEmpty { task = link.text }
        focused = true
    }

    private func start() {
        guard canStart, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        starting = true
        failure = nil
        let launch = LaunchRequest(agent: agent, project: project, task: task, title: nil,
                                   plan: plan && chosenAgent?.canPlan == true,
                                   worktree: worktree && chosenProject?.canWorktree == true,
                                   model: chosenAgent?.models == nil ? nil : model)
        let pictures = images
        Task {
            let delivery = await client.start(launch, images: pictures)
            starting = false
            switch delivery {
            case .sent(let response):
                Haptics.success()
                dismiss()
                if let id = response.created { started(id) }
            case .waiting:
                // Kept on the phone: the Agents list shows it as waiting for your Mac, and it starts once the Mac answers.
                Haptics.success()
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
