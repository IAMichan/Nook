import SwiftUI
import AppKit

/// Your agents at a glance, in two views.
/// Sessions: currently running at the top (prominently marked), recent sessions below; selected item on the right.
/// Accounts: accounts per agent (personal, work…) with login, limits, and usage. Switch the default account
/// at the top with a single click; new sessions and Nook's brain will use that account.
struct AgentsTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var draft = ""
    /// Why the last action in this tab failed, shown next to its buttons.
    @State private var actionError: String?
    /// An action is in progress (ending a process, taking over a conversation).
    @State private var working = false
    /// Progress through a multi-part question from the agent.
    @State private var questionID = ""
    @State private var questionStep = 0
    @State private var questionAnswers: [[String]] = []
    @State private var questionPicks: Set<String> = []

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case run(UUID)
        case nothing
    }

    var body: some View {
        let live = app.agentSessions
        let past = app.demoMode ? [] : Array(app.pastSessionsOutsideWorkspace.prefix(40))
        let selection = resolve(live: live, past: past)
        VStack(alignment: .leading, spacing: 12) {
            header(live: live, past: past, selection: selection)
            HStack(alignment: .top, spacing: 16) {
                sessionList(live: live, past: past, selection: selection)
                    .frame(width: 236)

                Rectangle().fill(NookTheme.line).frame(width: 1)

                Group {
                    switch selection {
                    case .live(let session): liveDetail(session)
                    case .past(let session): pastDetail(session)
                    case .run(let id): AgentRunPanel(workspace: app.workspace, runID: id)
                    case .nothing: nothingRunning
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            app.hub.refreshDetected()
            app.adoptAccounts()
            app.history.refresh()
        }
        .onChange(of: viewModel.selectedAgentID) { _, _ in
            actionError = nil
            draft = ""
        }
        // Keep sessions and usage up to date while the tab remains open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                app.adoptAccounts()
                app.history.refresh()
            }
        }
    }

    // MARK: Top bar

    private func header(live: [AgentSession], past: [PastSession], selection: Selection) -> some View {
        let tracked = live.filter { !$0.isDetected }
        let waiting = tracked.filter { $0.status == .waiting || $0.approvalID != nil }.count
        let working = tracked.filter { $0.status == .running }.count
        let badge: (String, Color)? = waiting > 0 ? ("\(waiting)", NookTheme.amber)
            : (working > 0 ? ("\(working)", NookTheme.iris) : (live.isEmpty ? nil : ("\(live.count)", NookTheme.textTertiary)))

        return HStack(spacing: 8) {
            Text(tr("agents.mode.sessions"))
                .font(NookTheme.font(13.5, .semibold))
                .foregroundStyle(NookTheme.paper)
            if let badge {
                Text(badge.0)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(badge.1)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Capsule().fill(badge.1.opacity(0.16)))
            }
            Spacer(minLength: 8)
            if !app.demoMode {
                // Starting a session and managing accounts happen in the window and in Settings, not here.
                NookGhostButton(title: tr("agents.newSession")) { app.openWorkspace(newSession: true) }
                WorkspaceButton(workspace: app.workspace) { app.openWorkspace() }
            }
        }
    }

    // MARK: Selection

    /// Content displayed on the right. Falls back sensibly if the selected item is gone: running items take priority.
    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), app.workspace.run(uuid) != nil {
            return .run(uuid)
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        if let first = live.first(where: { !$0.isDetected }) { return .live(first) }
        if !app.demoMode, let run = app.workspace.activeRuns.first(where: { !$0.archived }) { return .run(run.id) }
        if let first = past.first { return .past(first) }
        if let first = live.first { return .live(first) }
        return .nothing
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .run(let id): return "run:" + id.uuidString
        case .nothing: return ""
        }
    }

    // MARK: Sessions: list

    private func sessionList(live: [AgentSession], past: [PastSession], selection: Selection) -> some View {
        let tracked = live.filter { !$0.isDetected }
        let untracked = live.filter { $0.isDetected }
        let current = selectedID(selection)

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                if !tracked.isEmpty {
                    SectionHeader(title: tr("agents.nowActive"), trailing: "\(tracked.count)")
                    ForEach(tracked) { session in
                        LiveCard(session: session, account: accountTag(session), selected: current == session.id) {
                            viewModel.selectedAgentID = session.id
                        }
                    }
                }
                if !untracked.isEmpty {
                    SectionHeader(title: tr("agents.untrackedHeader"), trailing: "\(untracked.count)")
                        .padding(.top, tracked.isEmpty ? 0 : 12)
                    ForEach(untracked) { session in
                        UntrackedRow(session: session, account: accountTag(session), selected: current == session.id) {
                            viewModel.selectedAgentID = session.id
                        }
                    }
                }
                if live.isEmpty && past.isEmpty {
                    Text(tr("agents.noneWorkingNow"))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                if !app.demoMode {
                    WorkspaceRunsSection(workspace: app.workspace, selected: current) { id in
                        viewModel.selectedAgentID = "run:" + id.uuidString
                    }
                }
                if !past.isEmpty {
                    SectionHeader(title: tr("agents.recent"), trailing: app.history.loading ? tr("agents.checking") : nil)
                        .padding(.top, live.isEmpty ? 0 : 12)
                    ForEach(past) { session in
                        PastRow(session: session, account: accountTag(session), selected: current == "past:" + session.id) {
                            viewModel.selectedAgentID = "past:" + session.id
                        }
                    }
                }
            }
        }
    }

    /// "Work": only shown when you have multiple accounts for this agent, otherwise redundant.
    private func accountTag(_ session: AgentSession) -> String? {
        guard !app.demoMode, let profile = app.profile(for: session),
              app.profiles.profiles(for: profile.kind).count > 1 else { return nil }
        return displayName(profile)
    }

    private func accountTag(_ session: PastSession) -> String? {
        guard let profile = app.profile(for: session), app.profiles.profiles(for: profile.kind).count > 1 else { return nil }
        return displayName(profile)
    }

    /// Nothing active and no history: explain how to get started.
    private var nothingRunning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("agents.noneWorkingNow"))
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("agents.nothingRunningDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !app.demoMode {
                HStack(spacing: 4) {
                    NookPrimaryButton(title: tr("agents.newSession")) { app.openWorkspace(newSession: true) }
                    NookGhostButton(title: tr("agents.accountsInSettings")) { app.openSettings(section: .connections) }
                    Spacer()
                }
            }
        }
    }

    // MARK: Sessions: running

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
                    NookPrimaryButton(title: tr("button.allow")) { viewModel.finish("Toegestaan · npm install draait") }
                    NookGhostButton(title: tr("button.deny")) { viewModel.show(.idle) }
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

    // MARK: Sessions: past

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
                StatPill(title: tr("agents.lastActive"), value: AgentFormat.relative(session.ended))
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
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Data

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

// MARK: Formatting

private enum AgentFormat {
    private static var time: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private static var day: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }

    private static var weekday: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.shared.language.rawValue)
        formatter.dateFormat = "EEEEEE"
        return formatter
    }

    /// "just now", "12 min ago", "today 14:20", "yesterday 09:12", "Tue Oct 14".
    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return tr("agents.justNow") }
        if seconds < 3600 { return tr("agents.minAgo", Int(seconds / 60)) }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return tr("agents.todayAt", time.string(from: date)) }
        if calendar.isDateInYesterday(date) { return tr("agents.yesterdayAt", time.string(from: date)) }
        return day.string(from: date)
    }

    /// "< 1 min", "12 min", "1h 20m", "3 days".
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)u" : "\(hours)u \(minutes % 60)m" }
        return "\(hours / 24) d"
    }

    /// "resets at 15:40" or "resets Thu Oct 16".
    static func reset(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        if date.timeIntervalSinceNow < 20 * 3600 { return tr("agents.resetAt", time.string(from: date)) }
        return tr("agents.resetOn", day.string(from: date))
    }

    static func weekdayLetter(_ date: Date) -> String { weekday.string(from: date) }

    /// A session title stripped of tags Claude Code sometimes prefixes ("<pasted_content …>").
    static func title(_ raw: String) -> String {
        var text = raw
        if text.contains("<") {
            text = text.replacingOccurrences(of: "<[^>]*>?", with: " ", options: .regularExpression)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*-:· "))
        if text.isEmpty { return raw.contains("pasted") ? tr("agents.pastedText") : tr("agents.untitledSession") }
        return text
    }

    static func count(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    static func color(percent: Double) -> Color {
        switch percent {
        case ..<60: return NookTheme.mint
        case ..<85: return NookTheme.amber
        default: return NookTheme.coral
        }
    }
}

/// A single subscription limit: percentage consumed and reset time.
private struct UsageLimit: Identifiable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var id: String { label }
}

// MARK: Components

private struct SectionHeader: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(NookTheme.font(11.5, .semibold))
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(NookTheme.font(11, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.line2)
                Capsule().fill(color).frame(width: max(3, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 4)
    }
}

private struct StatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(NookTheme.font(10.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            Text(value)
                .font(NookTheme.font(12.5, .semibold))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(NookTheme.field))
    }
}

private struct Message: View {
    let author: String
    let text: String
    let color: Color
    /// Agent replies are Markdown; render them formatted instead of as raw text.
    var markdown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(author)
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(color)
            if markdown {
                MarkdownView(text: text, size: 12.5)
            } else {
                Text(text)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(Color(hex: 0xC9C7D2))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The conversation of a running session: what you asked and what the agent answered, newest at the bottom.
private struct AgentConversation: View {
    let session: AgentSession
    @State private var messages: [AgentChatMessage] = []

    private var agentColor: Color { AgentKind(agentName: session.name)?.color ?? NookTheme.iris }

    /// Messages from the transcript, or, without one, the last prompt and reply the hooks reported.
    private var shown: [AgentChatMessage] {
        if !messages.isEmpty { return messages }
        var fallback: [AgentChatMessage] = []
        if !session.lastPrompt.isEmpty { fallback.append(AgentChatMessage(id: "p", fromUser: true, text: session.lastPrompt)) }
        if !session.lastReply.isEmpty { fallback.append(AgentChatMessage(id: "r", fromUser: false, text: session.lastReply)) }
        return fallback
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    if shown.isEmpty {
                        Text(tr("agents.noMessagesInTranscript"))
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    ForEach(shown) { message in
                        bubble(message).id(message.id)
                    }
                    if session.status == .running {
                        HStack(spacing: 6) {
                            PulseDot(color: agentColor, animated: true)
                            Text(tr("agents.reply.working", session.name))
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                        .id("working")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))
            .onChange(of: shown) { _ in scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
        .task(id: session.id + session.transcriptPath) {
            // While the agent works the transcript keeps growing: read it again every couple of seconds.
            while !Task.isCancelled {
                let path = session.transcriptPath
                if !path.isEmpty {
                    let fresh = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
                    if fresh != messages { messages = fresh }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: AgentChatMessage) -> some View {
        if message.fromUser {
            HStack(spacing: 0) {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(NookTheme.font(13))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.iris.opacity(0.22)))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(agentColor)
                MarkdownView(text: message.text, size: 13)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let last = session.status == .running ? "working" : shown.last?.id
        guard let last else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }
}

/// A past session in the list.
private struct PastRow: View {
    let session: PastSession
    /// The account, shown only if you have multiple accounts for this agent.
    let account: String?
    let selected: Bool
    var showAgent = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(showAgent ? session.agent.color.opacity(0.8) : NookTheme.line2)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentFormat.title(session.title))
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper.opacity(0.92))
                        .lineLimit(1)
                    Text(([session.project] + (account.map { [$0] } ?? []) + [AgentFormat.relative(session.ended)]).joined(separator: " · "))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Color and label for the status of a tracked session.
private extension AgentSession {
    var liveColor: Color {
        if approvalID != nil { return NookTheme.amber }
        switch status {
        case .waiting: return NookTheme.amber
        case .running: return NookTheme.iris
        case .failed: return NookTheme.coral
        case .done: return NookTheme.mint
        case .detected: return NookTheme.textTertiary
        }
    }

    var liveLabel: String {
        if approvalID != nil { return tr("agents.live.waiting") }
        switch status {
        case .waiting: return tr("agents.live.waiting")
        case .running: return tr("agents.live.running")
        case .failed: return tr("agents.live.failed")
        case .done: return tr("agents.live.done")
        case .detected: return tr("agents.live.notTracked")
        }
    }
}

/// A dot that gently pulses while the agent is running.
private struct PulseDot: View {
    let color: Color
    let animated: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if animated {
                Circle()
                    .stroke(color.opacity(pulse ? 0 : 0.7), lineWidth: 1.5)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.3 : 1)
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Top of detail view: "● Working", "● Waiting for you", "Nook is not monitoring".
private struct StatusPill: View {
    let session: AgentSession

    var body: some View {
        let color = session.isDetected ? NookTheme.amber : session.liveColor
        HStack(spacing: 6) {
            if session.isDetected {
                Image(systemName: "eye.slash").font(.system(size: 10, weight: .bold))
            } else {
                PulseDot(color: color, animated: session.status == .running && session.approvalID == nil)
                    .frame(width: 12, height: 12)
            }
            Text(session.isDetected ? tr("agents.live.runningUntracked") : session.liveLabel)
                .font(NookTheme.font(12, .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// A tracked session: accented with its state color.
private struct LiveCard: View {
    let session: AgentSession
    let account: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = session.liveColor
        Button(action: action) {
            HStack(spacing: 10) {
                PulseDot(color: color, animated: session.status == .running && session.approvalID == nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project)
                        .font(NookTheme.font(13.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(([session.name] + (account.map { [$0] } ?? [])).joined(separator: " · "))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(session.liveLabel)
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(color)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(selected ? 0.18 : (hovering ? 0.12 : 0.08))))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(selected ? 0.55 : 0.25), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A running agent not tracked by Nook: muted appearance to avoid looking active.
private struct UntrackedRow: View {
    let session: AgentSession
    let account: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.project)
                        .font(NookTheme.font(12.5, .medium))
                        .foregroundStyle(NookTheme.paper.opacity(0.8))
                        .lineLimit(1)
                    Text(([session.name] + (account.map { [$0] } ?? []) + [tr("agents.live.untrackedShort")]).joined(separator: " · "))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(NookTheme.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("agents.live.untrackedHelp"))
    }
}

/// The step currently being executed: a shimmer effect traversing the text.
private struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x8A8896), location: 0),
                            .init(color: Color(hex: 0x8A8896), location: max(0, phase - 0.15)),
                            .init(color: NookTheme.paper, location: phase),
                            .init(color: Color(hex: 0x8A8896), location: min(1, phase + 0.15)),
                            .init(color: Color(hex: 0x8A8896), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
    }
}


// MARK: Workspace in the notch

/// "Workspace" at the top of the Agents tab, with a badge when sessions are running or waiting.
private struct WorkspaceButton: View {
    @ObservedObject var workspace: WorkspaceManager
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let waiting = workspace.runs.filter { $0.status == .waitingApproval }.count
        let active = workspace.activeRuns.count
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .semibold))
                Text(tr("ws.windowTitle"))
                    .font(NookTheme.font(12, .semibold))
                if waiting > 0 || active > 0 {
                    Text("\(waiting > 0 ? waiting : active)")
                        .font(NookTheme.mono(10.5, .semibold))
                        .foregroundStyle(waiting > 0 ? NookTheme.amber : NookTheme.iris)
                }
            }
            .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(NookTheme.field))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("ws.openHelp"))
    }
}

/// Sessions Nook runs itself (started here, taken over, or from the workspace): working, waiting, or recently finished.
/// Selecting one shows it in the tab, where you control it completely.
private struct WorkspaceRunsSection: View {
    @ObservedObject var workspace: WorkspaceManager
    let selected: String
    let open: (UUID) -> Void

    var body: some View {
        let recent = workspace.runs
            .filter { !$0.archived && ($0.status.isActive || Date().timeIntervalSince($0.updatedAt) < 24 * 3600) }
            .sorted { ($0.status.isActive ? 0 : 1, $1.updatedAt) < ($1.status.isActive ? 0 : 1, $0.updatedAt) }
            .prefix(8)
        if !recent.isEmpty {
            SectionHeader(title: tr("agents.inNook"), trailing: "\(recent.count)")
                .padding(.top, 12)
            ForEach(Array(recent)) { run in
                let isSelected = selected == "run:" + run.id.uuidString
                Button { open(run.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: run.status.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(run.status.color)
                            .symbolEffect(.pulse, options: .repeating, isActive: run.status == .running)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.title)
                                .font(NookTheme.font(12.5, .medium))
                                .foregroundStyle(NookTheme.paper.opacity(0.92))
                                .lineLimit(1)
                            Text([run.projectName, run.provider.kind.shortName, run.status.label].joined(separator: " · "))
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(run.status == .waitingApproval ? NookTheme.amber : NookTheme.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? NookTheme.field : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
