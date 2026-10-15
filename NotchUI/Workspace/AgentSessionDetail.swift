import SwiftUI
import AppKit

/// What an agent session in the list points at.
enum AgentSessionSelection {
    case live(AgentSession)
    case past(PastSession)
}

/// The detail of an agent session that is not run by Nook itself: a live session (hooks), a process Nook only sees, or an
/// earlier session from a transcript. The same view serves the notch (compact) and the main window.
struct AgentSessionDetail: View {
    @EnvironmentObject private var app: AppModel
    let selection: AgentSessionSelection
    @State private var draft = ""
    /// Why the last action in this view failed, shown next to its buttons.
    @State private var actionError: String?
    /// An action is in progress (ending a process, taking over a conversation).
    @State private var working = false
    /// Progress through a multi-part question from the agent.
    @State private var questionID = ""
    @State private var questionStep = 0
    @State private var questionAnswers: [[String]] = []
    @State private var questionPicks: Set<String> = []

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

    private func liveDetail(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    StatusPill(session: session)
                    Spacer()
                    if session.linesAdded + session.linesRemoved > 0 {
                        Text("+\(session.linesAdded) −\(session.linesRemoved)")
                            .font(NookTheme.mono(11.5, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                Text(session.project)
                    .font(NookTheme.font(17, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                accountLink(for: session)
            }

            if session.isDetected && !app.demoMode {
                untrackedExplanation(session)
            } else {
                trackedBody(session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Claude Code · Work · michiel@… · 5h 34%": which account this session is running under.
    @ViewBuilder
    private func accountLink(for session: AgentSession) -> some View {
        if !app.demoMode, let profile = app.profile(for: session) {
            HStack(spacing: 5) {
                Text(session.name).foregroundStyle(profile.kind.color)
                Text("·")
                Text(liveAccountLine(profile))
            }
            .font(NookTheme.font(12, .medium))
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
        } else {
            Text(session.name)
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private func liveAccountLine(_ profile: AgentProfile) -> String {
        var parts = [displayName(profile)]
        if let email = app.history.profileAccounts[profile.id]?.name, email != parts[0] { parts.append(email) }
        parts += limits(for: profile).map { "\($0.label.lowercased()) \(Int($0.percent.rounded()))%" }
        return parts.joined(separator: " · ")
    }

    /// Nook sees the process but not its conversation. Take it over (the conversation continues in Nook), end it, or link the agent.
    private func untrackedExplanation(_ session: AgentSession) -> some View {
        let kind = AgentKind(agentName: session.name)
        let profile = app.profile(for: session)
        let canTakeOver = app.canTakeOver(session)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(NookTheme.amber)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.isLinked ? tr("agents.untracked.startedBefore") : tr("agents.untracked.notLinked", session.name))
                        .font(NookTheme.font(14, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text(canTakeOver
                         ? tr("agents.untracked.takeOverDetail", session.name)
                         : tr("agents.untracked.endDetail", session.name))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !session.isLinked {
                        Text(tr("agents.untracked.linkHint", session.name))
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.amber.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.amber.opacity(0.22), lineWidth: 1))

            Spacer(minLength: 0)

            errorLine
            HStack(spacing: 4) {
                if working {
                    ProgressView().controlSize(.small).padding(.horizontal, 12)
                } else {
                    if canTakeOver {
                        NookPrimaryButton(title: tr("agents.nook.takeOver")) {
                            perform { try await app.continueInNook(session, endingTerminal: true) }
                        }
                    }
                    if app.canEnd(session) {
                        NookGhostButton(title: tr("agents.nook.end")) {
                            perform { try app.endSession(session) }
                        }
                    }
                }
                if !session.isLinked {
                    if let kind {
                        let target = profile ?? app.profiles.profile(id: kind.rawValue) ?? .defaultProfile(kind)
                        if app.agentConnect[target.id]?.isBusy == true {
                            ProgressView().controlSize(.small).padding(.horizontal, 12)
                        } else {
                            NookGhostButton(title: tr("agents.linkAgent", kind.shortName)) { app.connect(target) }
                        }
                    } else {
                        NookGhostButton(title: tr("agents.linkAgent", session.name)) { app.openSettings(section: .agents) }
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func trackedBody(_ session: AgentSession) -> some View {
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
                            .foregroundStyle(Color(hex: 0xC9C7D2))
                    }
                }
                .font(NookTheme.font(13))
                .lineLimit(1)
            }
        }

        if !app.demoMode, let question = app.hub.question(for: session.id) {
            questionPanel(question)
        } else if session.status == .waiting && session.approvalID == nil && !app.demoMode {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NookTheme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    // A long question scrolls instead of pushing the conversation and buttons out of view.
                    ScrollView(showsIndicators: true) {
                        Text(session.summary.isEmpty ? tr("agents.waiting.title", session.name) : session.summary)
                            .font(NookTheme.font(13, .semibold))
                            .foregroundStyle(NookTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(app.canTakeOver(session) ? tr("agents.waiting.answerHere") : tr("agents.waiting.cannotAnswer", session.name))
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.amber.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.amber.opacity(0.22), lineWidth: 1))
        }

        if session.approvalID != nil, !session.diff.isEmpty {
            // Scrolls within its height, so the whole change can be read before approving.
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

        if app.demoMode {
            Spacer(minLength: 0)
        } else {
            AgentConversation(session: session)
        }

        if !app.demoMode, let id = session.approvalID, let request = app.hub.approval(id: id) {
            let approval = ApprovalCenter.make(request)
            VStack(alignment: .leading, spacing: 6) {
                ApprovalView(approval: approval, maxHeight: 120) { app.approvals.decide(approval, $0) }
                HStack { Spacer(); sessionMenu(session) }
            }
        } else if app.demoMode {
            HStack(spacing: 4) {
                if session.status == .waiting {
                    NookPrimaryButton(title: tr("button.allow")) { app.viewModel.finish("Toegestaan · npm install draait") }
                    NookGhostButton(title: tr("button.deny")) { app.viewModel.show(.idle) }
                }
                TextField(
                    "",
                    text: $draft,
                    prompt: Text(session.placeholder).foregroundStyle(NookTheme.textTertiary)
                )
                .textFieldStyle(.plain)
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(NookTheme.field))
                NookIconButton(systemName: "arrow.up", label: tr("button.send"), filled: true) { draft = "" }
            }
        } else {
            replyBar(session)
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

    /// Reply field under the conversation. Nook continues the conversation itself: an idle session continues as is,
    /// a busy Claude Code session continues as a copy, and a session waiting on you is taken over (its terminal
    /// process ends, the conversation goes on here).
    @ViewBuilder
    private func replyBar(_ session: AgentSession) -> some View {
        let canTakeOver = app.canTakeOver(session)
        let kind = AgentKind(agentName: session.name)
        let waiting = session.status == .waiting
        let running = session.status == .running
        let takesOver = waiting || (running && kind != .claude)
        let prompt = !canTakeOver ? tr("agents.reply.unsupported", session.name)
            : (takesOver ? tr("agents.reply.takeOver") : (running ? tr("agents.reply.fork") : tr("agents.reply.continue")))
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, canTakeOver else { return }
            perform { try await app.continueInNook(session, message: text, endingTerminal: takesOver) }
        }
        VStack(alignment: .leading, spacing: 6) {
            errorLine
            HStack(spacing: 6) {
                if canTakeOver {
                    NookInputBar(text: $draft, prompt: prompt, busy: working, onStop: {}, onSend: send)
                } else {
                    Text(prompt)
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if session.approvalID == nil { sessionMenu(session) }
            }
            if canTakeOver && (running || waiting) {
                Text(takesOver ? tr("agents.reply.takeOverHint", session.name) : tr("agents.reply.forkHint"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Everything else for a running session: take it over in Nook, start a copy, or end it.
    private func sessionMenu(_ session: AgentSession) -> some View {
        let canTakeOver = app.canTakeOver(session)
        let busy = session.status == .running || session.status == .waiting
        return Menu {
            if canTakeOver {
                Button(tr("agents.nook.takeOver")) {
                    perform { try await app.continueInNook(session, endingTerminal: true) }
                }
                if busy && AgentKind(agentName: session.name) == .claude {
                    Button(tr("agents.nook.fork")) {
                        perform { try await app.continueInNook(session) }
                    }
                }
            }
            if app.canEnd(session) {
                if canTakeOver { Divider() }
                Button(tr("agents.nook.end"), role: .destructive) {
                    perform { try app.endSession(session) }
                }
            }
            if !session.cwd.isEmpty {
                Divider()
                Button(tr("button.openFolder")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                }
                Button(tr("button.openTerminalHere")) { app.openTerminal(in: session.cwd) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(NookTheme.field))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.nook.more"))
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

    private func pastDetail(_ session: PastSession) -> some View {
        let profile = app.profile(for: session)
        let canContinue = app.canContinueInNook(session)
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, canContinue else { return }
            perform { try await app.continueInNook(session, message: text) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentFormat.title(session.title))
                    .font(NookTheme.font(15, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.agent.name).foregroundStyle(session.agent.color)
                    if let profile, app.profiles.profiles(for: profile.kind).count > 1 {
                        Text("·")
                        Text(displayName(profile))
                    }
                    let meta = [session.project, session.branch, session.model].filter { !$0.isEmpty }
                    if !meta.isEmpty {
                        Text("·")
                        Text(meta.joined(separator: "  ·  "))
                    }
                }
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            }

            HStack(spacing: 8) {
                StatPill(title: tr("agents.lastActive"), value: NookDates.ago(session.ended))
                StatPill(title: tr("agents.duration"), value: AgentFormat.duration(session.duration))
                StatPill(title: tr("agents.questions"), value: "\(session.prompts)")
                StatPill(title: "Tokens", value: TokenTally.format(session.tokens.total))
            }

            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if !session.lastPrompt.isEmpty {
                        Message(author: tr("agents.you"), text: session.lastPrompt, color: NookTheme.textSecondary)
                    }
                    if !session.lastReply.isEmpty {
                        Message(author: session.agent.shortName, text: session.lastReply, color: session.agent.color, markdown: true)
                    }
                    if session.lastPrompt.isEmpty && session.lastReply.isEmpty {
                        Text(tr("agents.noMessagesInTranscript"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))

            errorLine
            if canContinue {
                HStack(spacing: 6) {
                    NookInputBar(text: $draft, prompt: tr("agents.reply.resume"), busy: working, onStop: {}, onSend: send)
                    NookGhostButton(title: tr("agents.nook.open")) {
                        perform { try await app.continueInNook(session) }
                    }
                    .help(tr("agents.nook.openHelp"))
                    if !session.cwd.isEmpty {
                        NookIconButton(systemName: "folder", label: tr("button.openFolder"), size: 30) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                        }
                        .help(tr("button.openFolder"))
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text(session.cwd.isEmpty ? tr("agents.nook.noFolder") : tr("agents.nook.unsupported", session.agent.name))
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !session.cwd.isEmpty {
                        NookGhostButton(title: tr("button.openFolder")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                        }
                        NookGhostButton(title: tr("button.openTerminalHere")) { app.openTerminal(in: session.cwd) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
