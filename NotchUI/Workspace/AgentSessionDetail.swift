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
    @State private var draft = ""
    @StateObject private var composerModel = ComposerModel()
    /// Why the last action in this view failed, shown above the composer.
    @State private var actionError: String?
    /// An action is in progress (sending, ending a process).
    @State private var working = false
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
        .onChange(of: selectionID) { _, _ in
            actionError = nil
            draft = ""
        }
    }

    private var selectionID: String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        }
    }

    // MARK: Header

    /// "nook / Agents-pagina rustiger maken" with the branch button on the right.
    private func header(folder: String, title: String, directory: String, agentWorking: Bool) -> some View {
        HStack(spacing: 8) {
            Text(folder)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Text("/").foregroundStyle(NookTheme.textTertiary)
            Text(title)
                .font(NookTheme.font(13.5, .medium))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !app.demoMode, let headerAccessory { headerAccessory }
            if !app.demoMode, !directory.isEmpty {
                FolderGitButton(directory: directory, agentWorking: agentWorking) {
                    app.viewModel.open(.folderChanges(directory))
                }
                .id(directory)
            }
        }
        .font(NookTheme.font(13.5))
        .frame(height: 30)
    }

    // MARK: Live session

    /// The transcript behind a session Nook only sees as a process (it was running before Nook started), or matching history.
    private func transcript(for session: AgentSession) -> PastSession? {
        if let transcript = app.detectedTranscripts()[session.id] { return transcript }
        if let id = app.conversationID(for: session), let past = app.history.sessions.first(where: { $0.sessionID == id }) {
            return past
        }
        guard !session.cwd.isEmpty, let kind = AgentKind(agentName: session.name) else { return nil }
        return app.history.sessions.first { $0.agent == kind && $0.cwd == session.cwd }
    }

    /// The earlier record of this conversation, for its title and branch.
    private func known(_ session: AgentSession) -> PastSession? {
        if let transcript = transcript(for: session) { return transcript }
        guard let id = app.conversationID(for: session) else { return nil }
        return app.history.sessions.first { $0.sessionID == id }
    }

    private func title(for session: AgentSession) -> String {
        if !session.summary.isEmpty { return AgentFormat.title(session.summary) }
        if let known = known(session), !known.title.isEmpty { return AgentFormat.title(known.title) }
        return session.name
    }

    /// The session as the conversation view needs it: with the transcript of a session that was already running.
    private func withTranscript(_ session: AgentSession) -> AgentSession {
        var shown = session
        if let transcript = transcript(for: session) {
            if shown.transcriptPath.isEmpty { shown.transcriptPath = transcript.path }
            if shown.lastPrompt.isEmpty { shown.lastPrompt = transcript.lastPrompt }
            if shown.lastReply.isEmpty { shown.lastReply = transcript.lastReply }
            if shown.sessionID.isEmpty { shown.sessionID = transcript.sessionID }
        }
        return shown
    }

    private func liveDetail(_ session: AgentSession) -> some View {
        let shown = withTranscript(session)
        return VStack(alignment: .leading, spacing: 12) {
            header(folder: session.project, title: title(for: session), directory: session.cwd,
                   agentWorking: session.status == .running || session.status == .waiting)

            if shown.transcriptPath.isEmpty && !session.steps.isEmpty {
                steps(session)
            }

            if !app.demoMode, let question = app.hub.question(for: session.id) {
                questionPanel(question)
            } else if session.status == .waiting && session.approvalID == nil && !app.demoMode, !session.summary.isEmpty {
                waitingNote(session)
            }

            if session.approvalID != nil, !session.diff.isEmpty {
                approvalDiff(session)
            }

            if app.demoMode {
                Spacer(minLength: 0)
            } else {
                // Every agent Nook can answer (Antigravity too, through its agent API), not only the ones it takes over.
                AgentConversation(session: shown, onReply: app.canReply(to: session) ? { answer in
                    perform { try await app.reply(to: session, message: answer) }
                } : nil)
            }

            if !app.demoMode, let id = session.approvalID, let request = app.hub.approval(id: id) {
                let approval = ApprovalCenter.make(request)
                ApprovalView(approval: approval, maxHeight: 120) { app.approvals.decide(approval, $0) }
            } else if !app.demoMode, let request = bridgeRequest(for: session) {
                // A command or pull request this agent asks for through Nook's workspace.
                let approval = ApprovalCenter.make(request)
                ApprovalView(approval: approval, maxHeight: 120) { app.approvals.decide(approval, $0) }
            } else {
                errorLine
                liveComposer(shown)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A workspace request from an agent running in a terminal in this session's folder.
    private func bridgeRequest(for session: AgentSession) -> BridgeRequest? {
        guard !session.cwd.isEmpty, !bridge.pending.isEmpty else { return nil }
        let folder = WorkspacePathPolicy.normalize(session.cwd)
        return bridge.pending.first { $0.caller.kind == .external && $0.caller.directory == folder }
    }

    /// The last few steps, for agents whose conversation Nook cannot read (it only hears their progress).
    private func steps(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.steps.suffix(3)) { step in
                let current = step.id == session.steps.last?.id && step.mark == .running && session.status == .running
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
                .font(NookTheme.font(13))
                .lineLimit(1)
            }
        }
    }

    /// The agent asks something in words (not a multiple-choice question): its question, quietly, above the composer.
    private func waitingNote(_ session: AgentSession) -> some View {
        ScrollView(showsIndicators: true) {
            Text(session.summary)
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 90)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.amber.opacity(0.22), lineWidth: 1))
    }

    /// The change an approval is about, scrollable so it can be read in full before deciding.
    private func approvalDiff(_ session: AgentSession) -> some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.file)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(session.diff) { line in
                    Text(line.text)
                        .foregroundStyle(line.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(NookTheme.mono(11.5))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: 110, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))
    }

    /// The composer under a live session. What you send continues the conversation in Nook: an idle session goes on as
    /// is, a busy Claude Code session as a copy, and one that waits on you, or still runs in a terminal, is taken over.
    @ViewBuilder
    private func liveComposer(_ session: AgentSession) -> some View {
        let canSend = app.canReply(to: session)
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, canSend else { return }
            let outgoing = composerModel.outgoing(text).send
            perform {
                try await app.reply(to: session, message: outgoing)
                draft = ""
            }
        }
        if app.demoMode {
            SessionComposer(text: $draft, prompt: session.placeholder, onSend: { draft = "" }) {
                agentPill(name: session.name, profile: nil)
            }
        } else {
            SessionComposer(
                text: $draft,
                prompt: canSend ? tr("agents.reply.followUp", session.name) : tr("agents.reply.unsupported", session.name),
                canSend: canSend,
                sending: working,
                onSend: send
            ) {
                sessionMenu(session)
                agentPill(name: session.name, profile: app.profile(for: session))
            }
            .rich(composerModel, composerConfig(folder: session.cwd, tint: NookTheme.iris))
            .trailing { ComposerMic(text: $draft) }
        }
    }

    /// The agent and account the conversation runs with; fixed for a session that exists.
    private func agentPill(name: String, profile: AgentProfile?) -> some View {
        let label = profile.map { AccountLabel.name($0, app: app) }
        return ComposerPill(agent: name, account: profile.map { AccountKind.of($0, app: app) },
                            text: [name, label].compactMap { $0 }.joined(separator: " · "), showsChevron: false)
    }

    /// End the session, or open its folder or a terminal there.
    private func sessionMenu(_ session: AgentSession) -> some View {
        let finishKey = FinishedSessions.key(agent: session.name, conversation: app.conversationID(for: session), fallback: session.id)
        let busy = session.status == .running || session.status == .waiting || session.approvalID != nil
        return ComposerPlusMenu(attach: { attachFile(in: session.cwd) }) {
            Divider()
            let isFinished = finishedMarks.isFinished(key: finishKey, idle: !busy && !session.isDetected, lastActive: session.updated)
            Button(isFinished ? tr("agents.finish.reopen") : tr("agents.finish.mark")) {
                if isFinished { finishedMarks.reopenByUser(finishKey) } else { finishedMarks.mark(finishKey) }
            }
            .disabled(busy)
            Divider()
            if app.canEnd(session) && app.canTakeOver(session) {
                Button(tr("agents.nook.takeOver")) {
                    perform { try await app.continueInNook(session, endingTerminal: true) }
                }
            }
            if app.canEnd(session) {
                Button(tr("agents.nook.end"), role: .destructive) {
                    perform { try app.endSession(session) }
                }
            }
            if !session.cwd.isEmpty {
                if app.canEnd(session) { Divider() }
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(NookTheme.amber)
                Text(context)
                    .font(NookTheme.font(11.5, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Text(item.question)
                .font(NookTheme.font(13.5, .semibold))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { _, option in
                        let chosen = picks.contains(option.label)
                        Button {
                            if item.multiSelect {
                                if fresh { questionID = request.id; questionStep = 0; questionAnswers = []; questionPicks = [] }
                                if chosen { questionPicks.remove(option.label) } else { questionPicks.insert(option.label) }
                            } else {
                                answer(request, index: index, labels: [option.label])
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.multiSelect ? (chosen ? "checkmark.square.fill" : "square") : "arrow.right.circle")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(chosen ? NookTheme.iris : NookTheme.textTertiary)
                                    .frame(width: 14)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(NookTheme.font(12.5, .semibold))
                                        .foregroundStyle(NookTheme.paper)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(NookTheme.font(11.5))
                                            .foregroundStyle(NookTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(chosen ? NookTheme.iris.opacity(0.14) : NookTheme.field))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 170)
            .fixedSize(horizontal: false, vertical: true)
            if item.multiSelect {
                HStack {
                    NookPrimaryButton(title: tr("agents.question.send")) {
                        answer(request, index: index, labels: Array(picks))
                    }
                    .disabled(picks.isEmpty)
                    .opacity(picks.isEmpty ? 0.5 : 1)
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.amber.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.amber.opacity(0.22), lineWidth: 1))
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
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(NookTheme.coral)
                Text(actionError)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
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
            guard !text.isEmpty, canContinue else { return }
            let outgoing = composerModel.outgoing(text).send
            perform {
                try await app.reply(to: session, message: outgoing)
                draft = ""
            }
        }
        return VStack(alignment: .leading, spacing: 12) {
            header(folder: session.project, title: AgentFormat.title(session.title), directory: session.cwd, agentWorking: false)

            // The whole conversation, with the agent's thinking, read from its transcript.
            TranscriptConversation(
                path: session.path, author: session.agent.name, accent: session.agent.color,
                fallback: pastFallback(session),
                onReply: canContinue ? { answer in
                    perform { try await app.reply(to: session, message: answer) }
                } : nil,
                footer: tr("agents.past.meta", NookDates.ago(session.ended), AgentFormat.duration(session.duration), session.prompts)
            )
            .id("past:" + session.id)

            errorLine
            SessionComposer(
                text: $draft,
                prompt: canContinue ? tr("agents.reply.resume")
                    : (session.cwd.isEmpty ? tr("agents.nook.noFolder") : tr("agents.nook.unsupported", session.agent.name)),
                canSend: canContinue,
                sending: working,
                onSend: send
            ) {
                // "Open in Nook" adopts the conversation: only for agents Nook runs itself (not Antigravity).
                pastMenu(session, canContinue: app.canContinueInNook(session))
                agentPill(name: session.agent.name, profile: app.profile(for: session))
            }
            .rich(composerModel, composerConfig(folder: session.cwd, tint: session.agent.color))
            .trailing { ComposerMic(text: $draft) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Without a readable transcript: the last prompt and reply the history scan kept.
    private func pastFallback(_ session: PastSession) -> [AgentChatMessage] {
        var messages: [AgentChatMessage] = []
        if !session.lastPrompt.isEmpty { messages.append(AgentChatMessage(id: "p", fromUser: true, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { messages.append(AgentChatMessage(id: "r", fromUser: false, text: session.lastReply)) }
        return messages
    }

    /// A file you add to the message: a reference in the text, the agent reads it itself.
    private func attachFile(in folder: String) {
        guard !folder.isEmpty, let ref = ComposerFilePicker.pick(startingIn: folder) else { return }
        draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + ContextRefs.link(ref) + " "
    }

    /// The same box as the chat and the sessions Nook runs: `/` commands are for those; here `@` points at files and the
    /// agent's own tint colors the box.
    private func composerConfig(folder: String, tint: Color) -> ComposerConfig {
        var config = ComposerConfig()
        config.tint = tint
        config.fileRoot = folder.isEmpty ? nil : folder
        config.keepsBigPastes = true
        return config
    }

    /// Open the whole conversation in Nook without a message, or its folder or a terminal there.
    private func pastMenu(_ session: PastSession, canContinue: Bool) -> some View {
        ComposerPlusMenu(attach: { attachFile(in: session.cwd) }) {
            Divider()
            if canContinue {
                Button(tr("agents.nook.open")) {
                    perform { try await app.continueInNook(session) }
                }
                Divider()
            }
            if !session.cwd.isEmpty {
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
        if account?.name == "API-sleutel" { return account?.name ?? "" }
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
