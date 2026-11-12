import SwiftUI
import AppKit

/// What an agent session in the list points at.
enum AgentSessionSelection {
    case live(AgentSession)
    case past(PastSession)
}

/// The detail of an agent session that is not run by Nook itself: a live session (hooks), one that was already running
/// when Nook started (read from its transcript), or an earlier one. On top the folder and the name with the branch on
/// the right, then the conversation, then the same composer a new session starts with: what you send continues the
/// conversation in Nook.
struct AgentSessionDetail: View {
    @EnvironmentObject private var app: AppModel
    let selection: AgentSessionSelection
    /// In the notch: the terminal and browser icons, next to the branch button.
    var headerAccessory: AnyView? = nil
    @Environment(\.sessionHeaderInset) private var headerInset
    /// What you type, held without being observed: as state of this view, every key drew the whole conversation above
    /// the composer again. Only the composer watches it (`Observing`), as in `AgentRunPanel`.
    @State private var composerState = SessionDraftState()
    private var draft: String {
        get { composerState.draft }
        nonmutating set { composerState.draft = newValue }
    }
    private var images: [ImageAttachment] {
        get { composerState.images }
        nonmutating set { composerState.images = newValue }
    }
    /// Held, not observed: only its suggestion list watches it (`ComposerSuggestionSlot`), so a key that changes the
    /// list does not redraw this whole panel.
    @State private var composerModel = ComposerModel()
    /// The keyboard is in the composer when the session opens, as in `AgentRunPanel`, also with a side panel open.
    @FocusState private var composerFocused: Bool
    /// Why the last action in this view failed, shown above the composer.
    @State private var actionError: String?
    /// Another agent, account or model picked in the composer; the next message continues the conversation with it.
    @State private var choice: AgentChoice?
    /// The mode, permissions and effort picked in the composer, for the session Nook continues the conversation in.
    @State private var turnSettings = AgentTurnSettings()
    /// An action is in progress (sending, ending a process).
    @State private var working = false
    /// The session whose terminal process is about to be ended (End session) or handed to Nook (Take over), while
    /// the confirmation asks first.
    @State private var endRequest: AgentSession?
    @State private var takeOverRequest: AgentSession?
    /// Progress through a multi-part question from the agent.
    @State private var questionID = ""
    @State private var questionStep = 0
    @State private var questionAnswers: [[String]] = []
    @State private var questionPicks: Set<String> = []
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var bridge = WorkspaceBridge.shared

    var body: some View {
        Group {
            switch selection {
            case .live(let session): liveDetail(session)
            case .past(let session): pastDetail(session)
            }
        }
        // "Reply" under an answer: it goes as a quote to the top of this session's composer, with the keyboard there.
        .environment(\.replyToAnswer, { answer in
            var text = draft
            ComposerFieldStyle.reply(to: answer, in: &text)
            draft = text
            composerFocused = true
        })
        .confirmDelete($endRequest, question: { tr("confirm.endSession", $0.name) },
                       detail: tr("confirm.endSession.detail"), confirmTitle: tr("agents.nook.end")) { session in
            perform { try app.endSession(session) }
        }
        .confirmDelete($takeOverRequest, question: { tr("confirm.endSession", $0.name) },
                       detail: tr("confirm.endSession.detail"), confirmTitle: tr("agents.nook.takeOver")) { session in
            perform { try await app.continueInNook(session, endingTerminal: true) }
        }
        .onAppear {
            composerState.show(session: selectionID)
            takeFromSidePanel()
        }
        // What the side panel hands to this session lands in the draft, to read before sending; also when it arrived
        // while this composer was not on screen.
        .onReceive(ComposerInbox.shared.$delivery.compactMap { $0 }) { _ in takeFromSidePanel() }
        .composerFocusOnAppear($composerFocused)
        .onChange(of: selectionID) { _, id in
            composerFocused = true
            actionError = nil
            // The draft of the session you leave stays with it; the one you open brings its own back.
            composerState.show(session: id)
            choice = nil
            turnSettings = AgentTurnSettings()
        }
    }

    private func takeFromSidePanel() {
        guard case .live(let session) = selection,
              let delivery = ComposerInbox.shared.take(run: nil, directory: session.cwd) else { return }
        draft = delivery.merged(into: draft)
        composerState.images += delivery.images
        composerFocused = true
    }

    private var selectionID: String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        }
    }

    // MARK: Header

    /// "nook / Agents-pagina rustiger maken" (click the folder for a new session in it) with the branch button on the right.
    private func header(folder: String, title: String, directory: String, agentWorking: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            // The folder keeps its name before the title gives way, but truncates too in a narrow window instead of
            // pushing the header past the conversation.
            FolderCrumb(name: folder, directory: directory)
                .layoutPriority(1)
            Text("/").foregroundStyle(NookTheme.textTertiary)
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !app.demoMode, !directory.isEmpty {
                FolderGitButton(directory: directory, agentWorking: agentWorking) {
                    // Next to the conversation when it has the side panel, otherwise as a task of its own.
                    if headerAccessory != nil {
                        app.viewModel.sessionTool = .changes
                    } else {
                        app.viewModel.open(.folderChanges(directory))
                    }
                }
                .id(directory)
            }
            if !app.demoMode, let headerAccessory { headerAccessory }
        }
        .font(NookTheme.TextStyle.body)
        .frame(height: 30)
        .padding(.leading, headerInset)
        .conversationHeaderBackground()
    }

    // MARK: Live session

    /// The transcript behind a session Nook only sees as a process (it was running before Nook started), or matching history.
    private func transcript(for session: AgentSession) -> PastSession? {
        // Only processes Nook merely sees have one, and working it out merges every session list: not for the others,
        // and this runs several times per redraw (and per keystroke in the reply field).
        if session.isDetected, let transcript = app.detectedTranscripts()[session.id] { return transcript }
        if let id = app.conversationID(for: session), let past = app.history.sessions.first(where: { $0.isConversation(id) }) {
            return past
        }
        guard !session.cwd.isEmpty, let kind = AgentKind(agentName: session.name) else { return nil }
        return app.history.sessions.first { $0.agent == kind && $0.cwd == session.cwd }
    }

    private func title(for session: AgentSession, known: PastSession?) -> String {
        let named = AgentFormat.sessionTitle(session, known: known)
        return named.isEmpty ? session.name : named
    }

    /// The session as the conversation view needs it: with the transcript of a session that was already running.
    private func withTranscript(_ session: AgentSession, _ transcript: PastSession?) -> AgentSession {
        var shown = session
        if let transcript {
            if shown.transcriptPath.isEmpty { shown.transcriptPath = transcript.path }
            if shown.lastPrompt.isEmpty { shown.lastPrompt = transcript.lastPrompt }
            if shown.lastReply.isEmpty { shown.lastReply = transcript.lastReply }
            if shown.sessionID.isEmpty { shown.sessionID = transcript.sessionID }
        }
        return shown
    }

    private func liveDetail(_ session: AgentSession) -> some View {
        // The earlier record of this conversation (its transcript, title and branch), looked up once per redraw.
        let past = transcript(for: session)
        let shown = withTranscript(session, past)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(folder: session.project, title: title(for: session, known: past), directory: session.cwd,
                   agentWorking: session.status == .running || session.status == .waiting || session.compactingSince != nil)

            if shown.transcriptPath.isEmpty && !session.steps.isEmpty {
                steps(session)
            }

            if app.demoMode {
                Spacer(minLength: 0)
                liveBottomBar(session, shown: shown, known: past)
            } else {
                // Every agent Nook can answer (Antigravity too, through its agent API), not only the ones it takes over.
                AgentConversation(session: shown, onReply: app.canReply(to: session) ? { answer in
                    perform { try await app.reply(to: session, message: answer) }
                } : nil, bottomBar: AnyView(liveBottomBar(session, shown: shown, known: past)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What sits under a live session's conversation: what the agent waits for, or the composer with its error line and
    /// tray. A question or an approval takes the composer's place until answered, in every kind of session.
    private func liveBottomBar(_ session: AgentSession, shown: AgentSession, known: PastSession?) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            // What the agent is waiting on stands right above where you answer.
            if session.status == .waiting && session.approvalID == nil && !app.demoMode, !session.summary.isEmpty,
               app.hub.question(for: session.id) == nil {
                waitingNote(session).chatColumn()
            }
            if session.approvalID != nil, !session.diff.isEmpty {
                approvalDiff(session).chatColumn()
            }
            // An approval goes first: the agent is held up on it now, and a question can outlive the hook that asked it.
            if !app.demoMode, let id = session.approvalID, let request = app.hub.approval(id: id) {
                let approval = ApprovalCenter.make(request)
                ApprovalView(approval: approval, inline: true, onDecide: { app.approvals.decide(approval, $0) },
                             onSecret: { app.approvals.allow(approval, secret: $0) },
                             onDenyWithReason: { app.approvals.decide(approval, .deny, reason: $0) })
                    .sessionComposerBounds()
            } else if !app.demoMode, let request = bridgeRequest(for: session) {
                // A command or pull request this agent asks for through Nook's workspace.
                let approval = ApprovalCenter.make(request)
                ApprovalView(approval: approval, inline: true, onDecide: { app.approvals.decide(approval, $0) },
                             onSecret: { app.approvals.allow(approval, secret: $0) })
                    .sessionComposerBounds()
            } else if !app.demoMode, let question = app.hub.question(for: session.id) {
                questionPanel(question).chatColumn().sessionComposerBounds()
            } else {
                errorLine
                VStack(spacing: 0) {
                    pullRequestTray(pullRequest(cwd: session.cwd, branch: known.flatMap { $0.branch.isEmpty ? nil : $0.branch } ?? GitHead.branch(for: session.cwd) ?? "", reply: pullRequestText(shown)), cwd: session.cwd)
                    liveComposer(shown).zIndex(1)
                }
                // The tray keeps to the box's column, so it follows the box when that is narrower than the panel.
                .chatColumn()
            }
        }
    }

    /// A workspace request from an agent running in a terminal in this session's folder.
    private func bridgeRequest(for session: AgentSession) -> BridgeRequest? {
        guard !session.cwd.isEmpty, !bridge.pending.isEmpty else { return nil }
        let folder = WorkspacePathPolicy.normalize(session.cwd)
        return bridge.pending.first { $0.caller.kind == .external && $0.caller.directory == folder }
    }

    /// The last few steps, for agents whose conversation Nook cannot read (it only hears their progress).
    private func steps(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(session.steps.suffix(3)) { step in
                let current = step.id == session.steps.last?.id && step.mark == .running
                    && (session.status == .running || session.compactingSince != nil)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(step.symbol)
                        .foregroundStyle(step.color)
                        .frame(width: 12)
                    if current {
                        ShimmerText(text: step.text)
                    } else {
                        Text(step.text)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
                .font(NookTheme.TextStyle.body)
                .lineLimit(1)
            }
        }
    }

    /// The agent asks something in words (not a multiple-choice question): its question, quietly, above the composer.
    private func waitingNote(_ session: AgentSession) -> some View {
        ScrollView {
            Text(session.summary)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 90)
        .fixedSize(horizontal: false, vertical: true)
        .conversationCard()
    }

    /// The change an approval is about, scrollable so it can be read in full before deciding.
    private func approvalDiff(_ session: AgentSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.file)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.bottom, NookTheme.Spacing.xs)
                ForEach(session.diff) { line in
                    Text(line.text)
                        .foregroundStyle(line.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(NookTheme.mono(11.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: 110, alignment: .topLeading)
        .roundedBackground(NookTheme.well, radius: NookTheme.Radius.card)
    }

    /// The pull request of a session Nook does not run: the open one for its folder and branch, else the last one its
    /// reply links, else the branch's one that merged or closed. Shown in a tray above the composer, as for a session
    /// Nook runs.
    private func pullRequest(cwd: String, branch: String, reply: String) -> URL? {
        let links = cwd.isEmpty || branch.isEmpty ? [] : PullRequestSync.shared.folderLinks[PullRequestSync.folderKey(path: cwd, branch: branch)] ?? []
        if let open = PullRequestLink.shown(in: links.filter(\.state.isOpen)) { return open }
        return MarkdownBlock.lastGitHubPullRequest(in: reply) ?? PullRequestLink.shown(in: links)
    }

    /// What a live session said, for a pull request link: its last reply, and for an agent whose conversation Nook cannot
    /// read (Antigravity, for one) what it reported while it worked.
    private func pullRequestText(_ session: AgentSession) -> String {
        ([session.lastReply, session.summary] + session.steps.suffix(10).map(\.text)).joined(separator: "\n")
    }

    /// The tray above a composer with the session's pull request in it (its state, checks and a way to open it).
    private func pullRequestTray(_ url: URL?, cwd: String) -> some View {
        FolderPullRequestTray(found: url, cwd: cwd)
    }

    /// The composer under a live session. What you send continues the conversation in Nook: an idle session goes on as
    /// is, a busy Claude Code session as a copy, and one that waits on you, or still runs in a terminal, is taken over.
    private func liveComposer(_ session: AgentSession) -> some View {
        // Worked out once per session change, not on every key: both look through the history, and for some agents
        // check the disk.
        let canSend = app.canReply(to: session)
        let canTakeOver = app.canTakeOver(session)
        return Observing(composerState) { liveComposerContent(session, canSend: canSend, canTakeOver: canTakeOver) }
    }

    @ViewBuilder
    private func liveComposerContent(_ session: AgentSession, canSend: Bool, canTakeOver: Bool) -> some View {
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard composerModel.hasContent(text), canSend, !working else { return }
            let savedDraft = draft
            let savedImages = images
            let outgoing = composerModel.outgoing(text).send
            let picked = choice
            let settings = turnSettings
            draft = ""
            images = []
            choice = nil
            turnSettings = AgentTurnSettings()
            perform {
                do {
                    try await app.reply(to: session, message: outgoing, choice: picked, settings: settings)
                } catch {
                    draft = savedDraft
                    images = savedImages
                    choice = picked
                    turnSettings = settings
                    throw error
                }
            }
        }
        if app.demoMode {
            SessionComposer(text: $composerState.draft, prompt: session.placeholder, onSend: { draft = "" }) {
                agentPill(name: session.name, profile: nil)
            }
            .images($composerState.images)
        } else {
            SessionComposer(
                text: $composerState.draft,
                prompt: canSend ? tr("agents.reply.followUp", choice?.provider.displayName ?? session.name)
                    : tr("agents.reply.unsupported", session.name),
                canSend: canSend,
                sending: working,
                focus: $composerFocused,
                busy: false,
                onSend: send
            ) {
                sessionMenu(session)
                agentMenu(name: session.name, kind: AgentKind(agentName: session.name), profile: app.profile(for: session),
                          canSwitch: canTakeOver)
                if canTakeOver { turnControls(kind: AgentKind(agentName: session.name)) }
                ComposerUsageRing.forAccount(app.profile(for: session), app: app)
            }
            .rich(composerModel, composerConfig(folder: session.cwd))
            .images($composerState.images)
            .dictating()
        }
    }

    /// The agent, account and model to continue with. The session runs outside Nook, so a pick waits for the next
    /// message: sending continues the conversation in Nook with it (another agent or account starts from a summary of
    /// what happened, a model counts from that message on). Without a way to continue in Nook the pill stays fixed.
    @ViewBuilder
    private func agentMenu(name: String, kind: AgentKind?, profile: AgentProfile?, canSwitch: Bool) -> some View {
        if canSwitch, let own = app.nookProvider(for: kind) {
            let original = AgentChoice(provider: own, profileID: profile?.id ?? own.kind.rawValue, model: "")
            let current = choice ?? original
            let shown = app.profiles.profile(id: current.profileID)
            let account = shown.map { AccountLabel.name($0, app: app) }
            let model = current.model.isEmpty ? nil : app.modelName(current.model, for: current.provider, profileID: current.profileID)
            let providers = app.connectedProviders
            ModelPickerDropdown {
                ComposerPill(agent: current.provider.displayName, account: AccountTag.badge(shown, app: app),
                             text: [current.provider.displayName, account, model].compactMap { $0 }.joined(separator: " · "),
                             short: model ?? current.provider.displayName)
            } content: {
                AgentModelPicker(providers: providers, provider: current.provider, profileID: current.profileID,
                                 model: current.model, showsAccounts: true) { provider, accountID, option in
                    let same = provider == current.provider
                    let next = AgentChoice(
                        provider: provider,
                        profileID: accountID ?? (same ? current.profileID : app.connectedProfiles(for: provider).first?.id ?? current.profileID),
                        model: option ?? (same ? current.model : app.workspace.settings.model(for: provider)))
                    choice = next == original ? nil : next
                }
            }
            .composerTip(tr("agents.reply.switchHelp"))
        } else {
            agentPill(name: name, profile: profile)
        }
    }

    /// The agent and account the conversation runs with, when Nook cannot continue it with another one.
    private func agentPill(name: String, profile: AgentProfile?) -> some View {
        let label = profile.map { AccountLabel.name($0, app: app) }
        return ComposerPill(agent: name, account: AccountTag.badge(profile, app: app),
                            text: [name, label].compactMap { $0 }.joined(separator: " · "), short: name, showsChevron: false)
    }

    /// The mode, permissions and effort the conversation continues with in Nook, as a session Nook runs shows them.
    @ViewBuilder
    private func turnControls(kind: AgentKind?) -> some View {
        if let own = app.nookProvider(for: kind) {
            let provider = choice?.provider ?? own
            let permission = turnSettings.permission ?? app.workspace.settings.permission(for: provider)
            ComposerDivider()
            ModeToggle(mode: $turnSettings.mode)
            ComposerDivider()
            ComposerDropdown(width: 300) {
                ComposerPill(symbol: turnSettings.mode == .plan ? "lock" : permission.symbol,
                             text: turnSettings.mode == .plan ? tr("compose.readOnly") : permission.label,
                             tint: permission == .bypass && turnSettings.mode != .plan ? NookTheme.coralSoft : nil)
            } content: {
                DropdownHeader(title: tr("compose.access"))
                ForEach(provider.capabilities.policies) { policy in
                    DropdownRow(symbol: policy.symbol, title: policy.label, detail: policy.help(for: provider),
                                chosen: permission == policy, tint: policy == .bypass ? NookTheme.coralSoft : nil) {
                        turnSettings.permission = policy
                    }
                }
            }
            .disabled(turnSettings.mode == .plan)
            .composerTip(permission.help(for: provider))
            let levels = app.workspace.effortLevels(for: provider, profileID: choice?.profileID, model: choice?.model ?? "")
            if !levels.isEmpty {
                ComposerDivider()
                Menu {
                    ForEach([nil] + levels.map { Optional($0) }, id: \.self) { level in
                        Button { turnSettings.effort = level } label: {
                            let title = app.workspace.effortTitle(level, for: provider, profileID: choice?.profileID)
                            if turnSettings.effort == level { Label(title, icon: "checkmark") } else { Text(title) }
                        }
                    }
                } label: {
                    ComposerPill(symbol: "gauge.with.dots.needle.33percent",
                                 text: app.workspace.effortTitle(turnSettings.effort, for: provider, profileID: choice?.profileID))
                }
                .composerMenu()
                .composerTip(tr("compose.effort.help"))
            }
        }
    }

    /// Attach a file, end the session, or open its folder or a terminal there.
    private func sessionMenu(_ session: AgentSession) -> some View {
        let finishKey = FinishedSessions.key(session: session)
        let busy = session.status == .running || session.status == .waiting || session.approvalID != nil
        let isFinished = finishedMarks.contains(finishKey)
        return ComposerPlusMenu(attach: { attachFile(in: session.cwd) }, screenshot: { app.captureFrontWindow() }) {
            Divider()
            Button(isFinished ? tr("agents.finish.reopen") : tr("agents.finish.mark")) {
                if isFinished { finishedMarks.reopenByUser(finishKey) } else { finishedMarks.mark(finishKey) }
            }
            .disabled(busy)
            if app.canEnd(session) && app.canTakeOver(session) {
                Button(tr("agents.nook.takeOver")) { takeOverRequest = session }
            }
            if app.canEnd(session) {
                Button(tr("agents.nook.end"), role: .destructive) { endRequest = session }
            }
            if !session.cwd.isEmpty {
                Divider()
                Button(tr("button.openFolder")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                }
                Button(tr("button.openTerminalHere")) { app.openTerminal(in: session.cwd) }
            }
        }
    }

    /// A multiple-choice question from the agent (AskUserQuestion), answered right here: one question at a time.
    private func questionPanel(_ request: AgentQuestionRequest) -> some View {
        let fresh = request.id != questionID
        let index = fresh ? 0 : min(questionStep, request.items.count - 1)
        let item = request.items[index]
        let picks: Set<String> = fresh ? [] : questionPicks
        var context = tr("agents.question.asks", request.agentName)
        if !item.header.isEmpty { context += " · " + item.header }
        if request.items.count > 1 { context += " · \(index + 1)/\(request.items.count)" }
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: "questionmark.bubble.fill").foregroundStyle(NookTheme.amber)
                Text(context)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Text(item.question)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                        let chosen = picks.contains(option.label)
                        SessionQuestionOptionButton(
                            option: option,
                            number: number,
                            chosen: chosen,
                            multiSelect: item.multiSelect
                        ) {
                            if item.multiSelect {
                                if fresh { questionID = request.id; questionStep = 0; questionAnswers = []; questionPicks = [] }
                                if chosen { questionPicks.remove(option.label) } else { questionPicks.insert(option.label) }
                            } else {
                                answer(request, index: index, labels: [option.label])
                            }
                        }
                        // What the option would look like, under it (Claude Code's `preview`).
                        QuestionOptionPreview(text: QuestionPreview.display(option.preview),
                                              indent: SessionQuestionOptionButton.labelIndent)
                            .padding(.bottom, option.preview.isEmpty ? 0 : NookTheme.Spacing.xs)
                    }
                }
            }
            .scrollIndicators(.never)
            // Previews make the options taller: more room before they scroll.
            .frame(maxHeight: item.options.contains { !$0.preview.isEmpty } ? 380 : 220)
            .fixedSize(horizontal: false, vertical: true)
            if item.multiSelect {
                HStack {
                    NookPrimaryButton(title: tr("agents.question.send")) {
                        answer(request, index: index, labels: Array(picks))
                    }
                    .disabled(picks.isEmpty)
                    Spacer()
                }
            }
        }
        .conversationCard()
    }

    private func answer(_ request: AgentQuestionRequest, index: Int, labels: [String]) {
        let earlier = request.id == questionID ? questionAnswers : []
        let all = Array(earlier.prefix(index)) + [labels]
        if index + 1 < request.items.count {
            questionID = request.id
            questionAnswers = all
            questionStep = index + 1
            questionPicks = []
        } else {
            app.hub.answerQuestion(request.id, selections: all)
            questionID = ""
            questionAnswers = []
            questionStep = 0
            questionPicks = []
        }
    }

    /// Why the last action failed, right above the buttons that caused it.
    @ViewBuilder
    private var errorLine: some View {
        if let actionError {
            ComposerErrorLine(message: actionError)
        }
    }

    /// Runs an action from this tab, showing progress and any error in place.
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        actionError = nil
        Task { @MainActor in
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
            working = false
        }
    }

    // MARK: Earlier session

    private func pastDetail(_ session: PastSession) -> some View {
        let canContinue = app.canReply(to: session)
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard composerModel.hasContent(text), canContinue, !working else { return }
            let savedDraft = draft
            let savedImages = images
            let outgoing = composerModel.outgoing(text).send
            let picked = choice
            let settings = turnSettings
            draft = ""
            images = []
            choice = nil
            turnSettings = AgentTurnSettings()
            perform {
                do {
                    try await app.reply(to: session, message: outgoing, choice: picked, settings: settings)
                } catch {
                    draft = savedDraft
                    images = savedImages
                    choice = picked
                    turnSettings = settings
                    throw error
                }
            }
        }
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header(folder: session.project, title: AgentFormat.title(session.title), directory: session.cwd, agentWorking: false)

            // The whole conversation, with the agent's thinking, read from its transcript.
            TranscriptConversation(
                path: session.path, author: session.agent.name, accent: session.agent.color,
                fallback: pastFallback(session),
                onReply: canContinue ? { answer in
                    perform { try await app.reply(to: session, message: answer) }
                } : nil,
                footer: tr("agents.past.meta", NookDates.ago(session.ended), AgentFormat.duration(session.duration), session.prompts),
                bottomBar: AnyView(pastBottomBar(session, canContinue: canContinue, send: send)),
                directory: session.cwd
            )
            .id("past:" + session.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The composer under an earlier session's conversation, with its error line and pull request tray.
    private func pastBottomBar(_ session: PastSession, canContinue: Bool, send: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            errorLine
            VStack(spacing: 0) {
                pullRequestTray(pullRequest(cwd: session.cwd, branch: session.branch.isEmpty ? (GitHead.branch(for: session.cwd) ?? "") : session.branch, reply: session.lastReply), cwd: session.cwd)
                Observing(composerState) {
                    SessionComposer(
                        text: $composerState.draft,
                        prompt: canContinue ? tr("agents.reply.resume")
                            : (session.cwd.isEmpty ? tr("agents.nook.noFolder") : tr("agents.nook.unsupported", session.agent.name)),
                        canSend: canContinue,
                        sending: working,
                        focus: $composerFocused,
                        busy: false,
                        onSend: send
                    ) {
                        // "Open in Nook" adopts the conversation: only for agents Nook runs itself (not Antigravity).
                        pastMenu(session, canContinue: app.canContinueInNook(session))
                        agentMenu(name: session.agent.name, kind: session.agent, profile: app.profile(for: session),
                                  canSwitch: app.canContinueInNook(session))
                        if app.canContinueInNook(session) { turnControls(kind: session.agent) }
                        ComposerUsageRing.forAccount(app.profile(for: session), app: app)
                    }
                    .rich(composerModel, composerConfig(folder: session.cwd))
                    .images($composerState.images)
                    .dictating()
                }
                .zIndex(1)
            }
            .chatColumn()
        }
    }

    /// Without a readable transcript: the last prompt and reply the history scan kept.
    private func pastFallback(_ session: PastSession) -> [AgentChatMessage] {
        var messages: [AgentChatMessage] = []
        if !session.lastPrompt.isEmpty { messages.append(AgentChatMessage(id: "p", fromUser: true, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { messages.append(AgentChatMessage(id: "r", fromUser: false, text: session.lastReply)) }
        return messages
    }

    /// A file you add to the message: a tile above the box and a reference the agent reads itself.
    private func attachFile(in folder: String) {
        guard !folder.isEmpty, let ref = ComposerFilePicker.pick(startingIn: folder) else { return }
        draft = ComposerAttachments.appending(ref, to: draft)
    }

    /// The same box as the chat and the sessions Nook runs: `/` commands are for those; here `@` points at files and the
    /// agent's own tint colors the box.
    private func composerConfig(folder: String) -> ComposerConfig {
        var config = ComposerConfig()
        config.fileRoot = folder.isEmpty ? nil : folder
        config.keepsBigPastes = true
        // An agent on this Mac reads the private file a pasted secret goes to.
        config.secretScope = SecretFiles.composerScope
        return config
    }

    /// Attach a file, open the whole conversation in Nook without a message, or its folder or a terminal there.
    private func pastMenu(_ session: PastSession, canContinue: Bool) -> some View {
        ComposerPlusMenu(attach: { attachFile(in: session.cwd) }, screenshot: { app.captureFrontWindow() }) {
            if canContinue {
                Divider()
                Button(tr("agents.nook.open")) { perform { try await app.continueInNook(session) } }
            }
            if !session.cwd.isEmpty {
                Divider()
                Button(tr("button.openFolder")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                }
                Button(tr("button.openTerminalHere")) { app.openTerminal(in: session.cwd) }
            }
        }
    }

    /// "Work", or for the first unnamed account: organization name, otherwise "Personal".
    private func displayName(_ profile: AgentProfile) -> String {
        if !profile.label.isEmpty { return profile.label }
        let account = app.history.profileAccounts[profile.id]
        if let org = account?.organization, !org.isEmpty { return org }
        if account?.name == AgentAccount.apiKeyName { return account?.name ?? "" }
        return tr("agents.personal")
    }

    /// The 5-hour and weekly subscription limits, if reported by the agent.
    private func limits(for profile: AgentProfile) -> [UsageLimit] {
        app.quota.limits(for: profile).map { UsageLimit(label: $0.label, percent: $0.percent, resetsAt: $0.resetsAt) }
    }

    private func plan(for profile: AgentProfile) -> String {
        if let plan = app.history.profileAccounts[profile.id]?.plan, !plan.isEmpty { return plan }
        return app.quota.codexPlan(for: profile)
    }
}

/// An interactive option row for session questions with clear hover state, keycap badge, and intuitive indicator
private struct SessionQuestionOptionButton: View {
    /// Where the option's words start: the row's padding, the keycap and the room after it.
    static let labelIndent = NookTheme.Spacing.md + 20 + NookTheme.Spacing.md

    let option: AgentQuestionOption
    let number: Int
    let chosen: Bool
    let multiSelect: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var parsedLabel: (title: String, badge: String?) {
        let label = option.label
        for tag in ["(Recommended)", "(Aanbevolen)", "(Recommandé)", "(Recomendado)"] {
            if let range = label.range(of: tag, options: .caseInsensitive) {
                let title = label.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
                let cleanTag = tag.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                return (title, cleanTag)
            }
        }
        return (label, nil)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                keycapBadge

                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text(parsedLabel.title)
                            .font(NookTheme.font(13, .semibold))
                            .foregroundStyle(chosen ? NookTheme.paper : (isHovered ? NookTheme.paper : NookTheme.paper.opacity(0.92)))

                        if let badge = parsedLabel.badge {
                            Text(badge)
                                .font(NookTheme.font(10, .semibold))
                                .foregroundStyle(NookTheme.amber)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.amber.opacity(0.18)))
                        }
                    }

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(isHovered || chosen ? NookTheme.paper.opacity(0.78) : NookTheme.textSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 4)

                trailingIndicator
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(backgroundColor, radius: NookTheme.Radius.control)
            .roundedStroke(borderColor, radius: NookTheme.Radius.control, lineWidth: isHovered || chosen ? 1.2 : 1)
            .roundedHitShape(NookTheme.Radius.control)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovered {
                NSCursor.pop()
                isHovered = false
            }
        }
        .animation(NookTheme.hover, value: isHovered)
        .animation(NookTheme.reveal, value: chosen)
    }

    private var keycapBadge: some View {
        ZStack {
            NookTheme.shape(NookTheme.Radius.chip)
                .fill(chosen ? NookTheme.amber.opacity(0.2) : (isHovered ? NookTheme.smoke : NookTheme.well))
            NookTheme.shape(NookTheme.Radius.chip)
                .stroke(chosen ? NookTheme.amber.opacity(0.6) : (isHovered ? NookTheme.amber.opacity(0.4) : NookTheme.wash.opacity(0.08)), lineWidth: 1)

            Text(number < 9 ? "\(number + 1)" : "·")
                .font(NookTheme.mono(11, .semibold))
                .foregroundStyle(chosen ? NookTheme.amber : (isHovered ? NookTheme.amber : NookTheme.textSecondary))
        }
        .frame(width: 20, height: 20)
        .padding(.top, 1)
    }

    @ViewBuilder
    private var trailingIndicator: some View {
        if multiSelect {
            Image(icon: chosen ? "checkmark.square.fill" : "square")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(chosen ? NookTheme.amber : (isHovered ? NookTheme.paper : NookTheme.textTertiary))
                .padding(.top, 2)
        } else {
            Image(icon: isHovered ? "arrow.right.circle.fill" : "circle")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(isHovered ? NookTheme.amber : NookTheme.wash.opacity(0.08))
                .opacity(isHovered ? 1 : 0.4)
                .padding(.top, 3)
        }
    }

    private var backgroundColor: Color {
        if chosen {
            return NookTheme.amber.opacity(0.12)
        } else if isHovered {
            return NookTheme.rowHover
        } else {
            return .clear
        }
    }

    private var borderColor: Color {
        chosen ? NookTheme.amber.opacity(0.55) : .clear
    }
}

/// The tray above the composer of a session Nook does not run: its pull request, and while the git button writes or
/// opens one for the folder, that already. Its own view, so only it redraws with the workspace, not the conversation.
private struct FolderPullRequestTray: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let found: URL?
    let cwd: String

    var body: some View {
        // The one the git button just opened for this folder comes first, before the sync has found it.
        let opened = cwd.isEmpty ? nil : workspace.folderPullRequests.first { cwd == $0.key || cwd.hasPrefix($0.key + "/") }?.value
        let url = opened ?? found
        let pending = workspace.quickGitProgress(folder: cwd).flatMap { $0.action.proposes ? $0.step : nil }
        if url != nil || pending != nil {
            ComposerTray(edge: .top) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if let url { PullRequestWatchStrip(url: url, watch: nil) }
                    if let pending { PullRequestPendingRow(step: pending) }
                }
            }
        }
    }
}

/// What you are writing under a session Nook did not start: its text and pictures. `AgentSessionDetail` holds it
/// without observing it, so typing draws the composer again and not the conversation.
@MainActor
final class SessionDraftState: ObservableObject {
    /// The session the draft belongs to: each change to it is saved for that session, as you type.
    private(set) var session: String?
    private var switching = false
    @Published var draft = "" {
        didSet {
            guard !switching, draft != oldValue, let session else { return }
            ComposerDraftStore.shared.save(sessionID: session, text: draft)
        }
    }

    /// Shows the draft saved for `session` (empty when there is none), saving nothing on the way: clearing the box of
    /// the session you leave is not a change you made to its draft.
    func show(session: String) {
        guard self.session != session else { return }
        switching = true
        defer { switching = false }
        self.session = session
        draft = ComposerDraftStore.shared.draft(for: session) ?? ""
    }
    @Published var images: [ImageAttachment] = []
}
