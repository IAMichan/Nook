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
    /// Enabled connections per account ("<profile>|<connection>"). Loaded on open, not on every redraw.
    @State private var linked: Set<String> = []
    @State private var copiedID: String?
    @State private var renaming: String?
    @State private var nameDraft = ""

    private enum Selection {
        case live(AgentSession)
        case past(PastSession)
        case account(AgentProfile)
        case nothing

        var isAccounts: Bool {
            switch self {
            case .account: return true
            default: return false
            }
        }
    }

    var body: some View {
        let live = app.agentSessions
        let past = app.demoMode ? [] : Array(app.pastSessionsOutsideWorkspace.prefix(40))
        let selection = resolve(live: live, past: past)
        VStack(alignment: .leading, spacing: 12) {
            header(live: live, past: past, selection: selection)
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if selection.isAccounts {
                        accountList(selection)
                    } else {
                        sessionList(live: live, past: past, selection: selection)
                    }
                }
                .frame(width: 236)

                Rectangle().fill(NookTheme.line).frame(width: 1)

                Group {
                    switch selection {
                    case .live(let session): liveDetail(session)
                    case .past(let session): pastDetail(session)
                    case .account(let profile): accountDetail(profile)
                    case .nothing: nothingRunning
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !selection.isAccounts && !app.demoMode {
                usageStrip
            }
        }
        .onAppear {
            app.hub.refreshDetected()
            app.adoptAccounts()
            app.history.refresh()
            refreshLinks()
        }
        .onChange(of: viewModel.selectedAgentID) { _, _ in
            refreshLinks()
            renaming = nil
        }
        .onChange(of: app.agentConnect) { _, _ in refreshLinks() }
        .onChange(of: app.profiles.all) { _, _ in refreshLinks() }
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

        return HStack(spacing: 6) {
            ModeButton(title: tr("agents.mode.sessions"), badge: badge, selected: !selection.isAccounts) {
                viewModel.selectedAgentID = live.first?.id ?? past.first.map { "past:" + $0.id } ?? ""
            }
            ModeButton(title: tr("agents.mode.accounts"), badge: nil, selected: selection.isAccounts) {
                viewModel.selectedAgentID = "account:" + app.profiles.preferredProfile(.claude).id
            }
            Spacer(minLength: 8)
            if !app.demoMode {
                ForEach(switcherKinds) { kind in
                    accountSwitcher(kind)
                }
                WorkspaceButton(workspace: app.workspace) { app.openWorkspace() }
            }
        }
    }

    /// Agents whose default account can be switched at the top: only those installed on this Mac that support multiple accounts.
    private var switcherKinds: [AgentKind] {
        AgentKind.allCases.filter { kind in
            kind.supportsProfiles && (app.history.installed.contains(kind) || app.profiles.profiles(for: kind).count > 1)
        }
    }

    /// "● Claude  Personal ⌄": one-click default account switching, or add an account.
    private func accountSwitcher(_ kind: AgentKind) -> some View {
        let current = app.profiles.preferredProfile(kind)
        let all = app.profiles.profiles(for: kind)
        return Menu {
            Section(tr("agents.switcher.defaultFor", kind.name)) {
                ForEach(all) { profile in
                    Toggle(isOn: Binding(
                        get: { app.profiles.isPreferred(profile) },
                        set: { if $0 { app.makeDefault(profile) } }
                    )) {
                        Text(menuLine(profile))
                    }
                }
            }
            Divider()
            Button(tr("agents.switcher.add")) { app.openSettings(section: .agents) }
            Button(tr("agents.switcher.manage")) { viewModel.selectedAgentID = "account:" + current.id }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(kind.color).frame(width: 6, height: 6)
                Text(kind.shortName)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(displayName(current))
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(NookTheme.field))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.switcher.help", kind.shortName))
    }

    private func menuLine(_ profile: AgentProfile) -> String {
        let name = displayName(profile)
        guard let email = app.history.profileAccounts[profile.id]?.name, email != name else {
            return name + " (" + tr("agents.notLoggedInShort") + ")"
        }
        return "\(name) · \(email)"
    }

    // MARK: Selection

    /// Content displayed on the right. Falls back sensibly if the selected item is gone: running items take priority.
    private func resolve(live: [AgentSession], past: [PastSession]) -> Selection {
        let id = viewModel.selectedAgentID
        if id.hasPrefix("account:") {
            let key = String(id.dropFirst(8))
            if let profile = app.profiles.profile(id: key) { return .account(profile) }
            if let kind = AgentKind(rawValue: key) { return .account(app.profiles.preferredProfile(kind)) }
            return .account(app.profiles.preferredProfile(.claude))
        }
        if id.hasPrefix("past:") {
            let key = String(id.dropFirst(5))
            if let session = app.history.sessions.first(where: { $0.id == key }) { return .past(session) }
        }
        if let session = live.first(where: { $0.id == id }) { return .live(session) }
        if let first = live.first(where: { !$0.isDetected }) { return .live(first) }
        if let first = past.first { return .past(first) }
        if let first = live.first { return .live(first) }
        return .nothing
    }

    private func selectedID(_ selection: Selection) -> String {
        switch selection {
        case .live(let session): return session.id
        case .past(let session): return "past:" + session.id
        case .account(let profile): return "account:" + profile.id
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
                    WorkspaceRunsSection(workspace: app.workspace) { id in app.openWorkspace(run: id) }
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

    /// Always visible at the bottom of Sessions: quota usage across all your accounts, even when idle.
    @ViewBuilder
    private var usageStrip: some View {
        let profiles = app.profiles.all.filter {
            app.history.executables[$0.kind] != nil || app.history.profileAccounts[$0.id] != nil
        }
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(NookTheme.line).frame(height: 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(profiles) { profile in
                            usageChip(profile)
                        }
                    }
                }
            }
        }
    }

    private func usageChip(_ profile: AgentProfile) -> some View {
        let windows = limits(for: profile)
        let several = app.profiles.profiles(for: profile.kind).count > 1
        let name = several ? "\(profile.kind.shortName) · \(displayName(profile))" : profile.kind.shortName
        return Button { viewModel.selectedAgentID = "account:" + profile.id } label: {
            HStack(spacing: 8) {
                Circle().fill(profile.kind.color).frame(width: 6, height: 6)
                Text(name)
                    .font(NookTheme.font(11.5, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                if app.history.profileAccounts[profile.id] == nil {
                    Text(tr("agents.notLoggedInShort"))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.amber)
                } else if windows.isEmpty {
                    Text(tr("agents.noLimitsYet"))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                } else {
                    ForEach(windows) { window in
                        HStack(spacing: 4) {
                            Text(window.label.lowercased())
                                .foregroundStyle(NookTheme.textTertiary)
                            Text("\(Int(window.percent.rounded()))%")
                                .font(NookTheme.mono(11, .semibold))
                                .foregroundStyle(AgentFormat.color(percent: window.percent))
                        }
                        .font(NookTheme.font(11.5))
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(NookTheme.field))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tr("agents.viewAccount"))
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
                    NookPrimaryButton(title: tr("ws.newSession")) { app.openWorkspace(newSession: true) }
                    startMenu(app.profiles.preferredProfile(.claude), primary: false)
                    NookGhostButton(title: tr("agents.mode.accounts")) {
                        viewModel.selectedAgentID = "account:" + app.profiles.preferredProfile(.claude).id
                    }
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

    /// "Claude Code · Work · michiel@… · 5h 34%  ›": indicates which account this session is running under.
    @ViewBuilder
    private func accountLink(for session: AgentSession) -> some View {
        if !app.demoMode, let profile = app.profile(for: session) {
            Button { viewModel.selectedAgentID = "account:" + profile.id } label: {
                HStack(spacing: 5) {
                    Text(session.name).foregroundStyle(profile.kind.color)
                    Text("·")
                    Text(liveAccountLine(profile))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(tr("agents.viewAccount"))
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

    /// Nook detects the process, but cannot inspect its internals. A single clear explanation and button, no step list.
    private func untrackedExplanation(_ session: AgentSession) -> some View {
        let kind = AgentKind(agentName: session.name)
        let profile = app.profile(for: session)
        let command = profile?.launchCommand ?? kind?.command ?? session.name.lowercased()
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
                    Text(session.isLinked
                         ? tr("agents.untracked.restartDetail", command)
                         : tr("agents.untracked.linkDetail", session.name))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.amber.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NookTheme.amber.opacity(0.22), lineWidth: 1))

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if session.isLinked {
                    terminalButton(session, primary: true)
                } else if let kind {
                    let target = profile ?? app.profiles.profile(id: kind.rawValue) ?? .defaultProfile(kind)
                    if app.agentConnect[target.id]?.isBusy == true {
                        ProgressView().controlSize(.small).padding(.horizontal, 12)
                    } else {
                        NookPrimaryButton(title: tr("agents.linkAgent", kind.shortName)) { app.connect(target) }
                    }
                    terminalButton(session)
                } else {
                    NookPrimaryButton(title: tr("agents.linkAgent", session.name)) { app.openSettings(section: .agents) }
                    terminalButton(session)
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

        if session.status == .waiting && session.approvalID == nil && !app.demoMode {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NookTheme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    // A long question scrolls instead of pushing the conversation and buttons out of view.
                    ScrollView(showsIndicators: true) {
                        Text(session.summary.isEmpty ? tr("agents.waitingInTerminal") : session.summary)
                            .font(NookTheme.font(13, .semibold))
                            .foregroundStyle(NookTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(tr("agents.waitingInTerminalDetail"))
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
            HStack(spacing: 4) {
                NookPrimaryButton(title: tr("button.allow")) { app.hub.decide(id, .allow) }
                if request.canAlways {
                    NookGhostButton(title: tr("button.always")) { app.hub.decide(id, .always) }
                }
                NookGhostButton(title: tr("button.deny")) { app.hub.decide(id, .deny) }
                Spacer()
                terminalButton(session)
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

    /// Reply field under the conversation: continues the session, or copies the text to the agent's terminal.
    private func replyBar(_ session: AgentSession) -> some View {
        let canContinue = app.canContinue(session)
        let busy = session.status == .running || session.status == .waiting
        let prompt = canContinue
            ? (busy ? tr("agents.reply.fork") : tr("agents.reply.continue"))
            : tr("agents.reply.copy")
        let send = {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            app.send(text, to: session)
            draft = ""
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                NookInputBar(text: $draft, prompt: prompt, onSend: send)
                terminalButton(session)
            }
            if canContinue && busy {
                Text(tr("agents.reply.forkHint"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func terminalButton(_ session: AgentSession, primary: Bool = false) -> some View {
        let title = tr("agents.openTerminal", TerminalLauncher.name(for: session.hostBundleID))
        if primary {
            NookPrimaryButton(title: title) { app.openTerminal(for: session) }
        } else {
            NookGhostButton(title: title) { app.openTerminal(for: session) }
        }
    }

    // MARK: Sessions: past

    private func pastDetail(_ session: PastSession) -> some View {
        let profile = app.profile(for: session)
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

            HStack(spacing: 4) {
                NookPrimaryButton(title: tr("button.resumeInTerminal")) { app.resume(session) }
                NookGhostButton(title: copiedID == session.id ? tr("button.copied") : tr("button.copyCommand")) {
                    app.copyResumeCommand(session)
                    copiedID = session.id
                }
                if !session.cwd.isEmpty {
                    NookGhostButton(title: tr("button.openFolder")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd, isDirectory: true))
                    }
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Accounts: list

    private func accountList(_ selection: Selection) -> some View {
        let current = selectedID(selection)
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(AgentKind.allCases) { kind in
                    HStack(spacing: 6) {
                        Circle().fill(kind.color).frame(width: 6, height: 6)
                        Text(kind.name)
                        Spacer()
                        if kind.supportsProfiles {
                            Button { app.openSettings(section: .agents) } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .bold))
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(tr("agents.addAccountHelp", kind.shortName))
                        }
                    }
                    .font(NookTheme.font(11.5, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, kind == AgentKind.allCases.first ? 0 : 10)

                    ForEach(app.profiles.profiles(for: kind)) { profile in
                        ProfileRow(
                            name: displayName(profile),
                            detail: rowDetail(profile),
                            warning: rowWarning(profile),
                            isDefault: app.profiles.profiles(for: kind).count > 1 && app.profiles.isPreferred(profile),
                            highest: limits(for: profile).map(\.percent).max(),
                            color: kind.color,
                            selected: current == "account:" + profile.id
                        ) {
                            viewModel.selectedAgentID = "account:" + profile.id
                        }
                    }
                }
            }
        }
    }

    private func rowDetail(_ profile: AgentProfile) -> String {
        if let progress = app.agentConnect[profile.id], progress.isBusy { return progress.text }
        let gap = missing(profile)
        if gap.program { return tr("agents.notInstalledShort") }
        if gap.login { return tr("agents.notLoggedInShort") }
        let email = app.history.profileAccounts[profile.id]?.name ?? ""
        return gap.targets.isEmpty ? email : tr("agents.notYetLinkedShort")
    }

    private func rowWarning(_ profile: AgentProfile) -> Bool {
        if app.agentConnect[profile.id]?.isBusy == true { return false }
        return !missing(profile).isEmpty
    }

    // MARK: Accounts: detail

    private func accountDetail(_ profile: AgentProfile) -> some View {
        let kind = profile.kind
        let account = app.history.profileAccounts[profile.id]
        let summary = app.history.profileUsage[profile.id] ?? AgentUsageSummary()
        let windows = limits(for: profile)
        let recent = Array(app.history.sessions(for: profile).prefix(5))
        let planName = plan(for: profile)
        let gap = missing(profile)
        let busy = app.agentConnect[profile.id]?.isBusy == true
        let failed: Bool = { if case .failed? = app.agentConnect[profile.id] { return true }; return false }()

        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        nameField(profile)
                        if !planName.isEmpty { Badge(text: planName, color: kind.color) }
                        Spacer()
                        if gap.isEmpty && !busy {
                            Label(tr("agents.linked"), systemImage: "checkmark.circle.fill")
                                .font(NookTheme.font(12, .semibold))
                                .foregroundStyle(NookTheme.mint)
                        }
                    }
                    Text(accountLine(profile, account))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }

                if !gap.isEmpty || busy || failed {
                    connectBar(profile)
                }

                if !gap.program {
                    Button { app.openSettings(section: .agents) } label: {
                        Label(tr("accounts.manageInSettings"), systemImage: "gearshape")
                            .font(NookTheme.font(12, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                if windows.isEmpty {
                    if !gap.program && !gap.login { limitHint(profile) }
                } else {
                    HStack(spacing: 10) {
                        ForEach(windows) { LimitCard(limit: $0) }
                    }
                    if kind == .claude, let updated = app.hub.subscriptionUsage(for: profile)?.updated {
                        Text(tr("agents.updatedFromStatusLine", AgentFormat.relative(updated)))
                            .font(NookTheme.font(11))
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.top, -6)
                    }
                }

                if kind != .gemini && account != nil {
                    HStack(alignment: .bottom, spacing: 10) {
                        StatCard(title: tr("agents.today"), value: TokenTally.format(summary.today.total) + " tokens",
                                 detail: AgentFormat.count(summary.sessionsToday, tr("agents.session"), tr("agents.sessions")))
                        StatCard(title: tr("agents.last7Days"), value: TokenTally.format(summary.week.total) + " tokens",
                                 detail: AgentFormat.count(summary.sessionsWeek, tr("agents.session"), tr("agents.sessions")))
                        DayBars(days: summary.perDay, color: kind.color)
                    }
                }

                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: tr("agents.recentWithAccount"), trailing: nil)
                        ForEach(recent) { session in
                            PastRow(session: session, account: nil, selected: false, showAgent: false) {
                                viewModel.selectedAgentID = "past:" + session.id
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The account name, with an edit icon to rename it ("Work", "Bettr").
    @ViewBuilder
    private func nameField(_ profile: AgentProfile) -> some View {
        if renaming == profile.id {
            TextField("", text: $nameDraft, prompt: Text(profile.isDefault ? tr("agents.personal") : tr("agents.name")).foregroundStyle(NookTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(NookTheme.font(15, .semibold))
                .foregroundStyle(NookTheme.paper)
                .padding(.horizontal, 8)
                .frame(width: 180, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(NookTheme.field))
                .onSubmit {
                    app.profiles.rename(profile.id, to: nameDraft)
                    renaming = nil
                }
                .onExitCommand { renaming = nil }
        } else {
            Button {
                nameDraft = profile.label
                renaming = profile.id
            } label: {
                HStack(spacing: 6) {
                    Text("\(profile.kind.shortName) · \(displayName(profile))")
                        .font(NookTheme.font(15, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .help(tr("agents.renameHelp"))
        }
    }

    private func accountLine(_ profile: AgentProfile, _ account: AgentAccount?) -> String {
        guard let account else {
            return app.history.executables[profile.kind] == nil ? tr("agents.notInstalled") : tr("agents.notLoggedIn")
        }
        var parts = [account.name]
        if !account.organization.isEmpty { parts.append(account.organization) }
        if !profile.isDefault { parts.append(profile.displayHome) }
        return parts.joined(separator: " · ")
    }

    /// "Start session": in a recent working directory, or choose another.
    private func startMenu(_ profile: AgentProfile, primary: Bool) -> some View {
        let folders = app.recentFolders(profile)
        return Menu {
            if !folders.isEmpty {
                Section(tr("agents.recentFolders")) {
                    ForEach(folders, id: \.self) { folder in
                        Button(AgentProfile.tildePath(folder)) { app.startSession(profile, in: folder) }
                    }
                }
            }
            Button(tr("agents.chooseFolder")) { app.startSessionChoosingFolder(profile) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                Text(app.profiles.profiles(for: profile.kind).count > 1 ? tr("agents.startWith", displayName(profile)) : tr("agents.startAgent", profile.kind.shortName))
                    .font(NookTheme.font(14, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(primary ? NookTheme.ink : NookTheme.paper)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(Capsule().fill(primary ? NookTheme.paper : NookTheme.field))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(app.history.executables[profile.kind] == nil)
    }

    // MARK: Connect

    private func refreshLinks() {
        var result: Set<String> = []
        for profile in app.profiles.all {
            let home = profile.isDefault ? nil : profile.homeURL
            for target in profile.kind.targets where AgentConfigInstaller.state(of: target, home: home) == .installed {
                result.insert(profile.id + "|" + target.rawValue)
            }
        }
        if result != linked { linked = result }
    }

    /// Missing prerequisites for this account.
    private struct Missing {
        var program: Bool
        var login: Bool
        var targets: [AgentConfigInstaller.Target]
        var isEmpty: Bool { !program && !login && targets.isEmpty }
    }

    private func missing(_ profile: AgentProfile) -> Missing {
        Missing(
            program: app.history.executables[profile.kind] == nil,
            login: app.history.profileAccounts[profile.id] == nil,
            targets: profile.kind.targets.filter { !linked.contains(profile.id + "|" + $0.rawValue) }
        )
    }

    /// A single button that configures everything for this account: install, login, and notch connections.
    private func connectBar(_ profile: AgentProfile) -> some View {
        let kind = profile.kind
        let gap = missing(profile)
        let progress = app.agentConnect[profile.id]
        let busy = progress?.isBusy == true
        let failed: Bool = { if case .failed? = progress { return true }; return false }()

        let title: String
        let detail: String
        if busy {
            title = progress?.text ?? tr("chat.plan.running")
            detail = tr("agents.followStepsInTerminal")
        } else if failed {
            title = tr("agents.linkFailed")
            detail = progress?.text ?? ""
        } else {
            title = gap.login && !profile.isDefault ? tr("agents.loginWithAccount") : tr("agents.linkWithOneClick", kind.shortName)
            var parts: [String] = []
            if gap.program { parts.append(tr("agents.installStep", kind.command)) }
            if gap.login { parts.append(tr("agents.loginStep")) }
            if !gap.targets.isEmpty {
                parts.append(kind == .claude ? tr("agents.enableLimitsStep") : tr("agents.enableProgressStep"))
            }
            detail = "Nook " + parts.joined(separator: ", ") + "."
        }
        let buttonTitle = gap.program ? tr("button.installAndLink") : (gap.login ? tr("agents.login") : tr("button.link"))

        return HStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "link")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(failed ? NookTheme.coral : kind.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(detail)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                NookPrimaryButton(title: failed ? tr("button.tryAgain") : buttonTitle) { app.connect(profile) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(kind.color.opacity(0.25), lineWidth: 1))
    }

    /// No rate limits known: explains why and how to make them visible.
    @ViewBuilder
    private func limitHint(_ profile: AgentProfile) -> some View {
        let kind = profile.kind
        let statusLineMissing = kind == .claude && !linked.contains(profile.id + "|" + AgentConfigInstaller.Target.claudeStatusLine.rawValue)
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                if statusLineMissing {
                    Text(tr("agents.seeLimits"))
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text(tr("agents.seeLimitsDetail"))
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                } else if kind == .gemini {
                    Text(tr("agents.noLimitsKnown"))
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text(tr("agents.noLimitsGemini"))
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                } else if kind == .codex && !profile.isDefault {
                    Text(tr("agents.codexLimitsFirstOnly"))
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text(tr("agents.codexLimitsFirstOnlyDetail"))
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                } else {
                    Text(tr("agents.noLimitsYet"))
                        .font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
                    Text(kind == .claude
                         ? tr("agents.noLimitsClaudeAccount")
                         : tr("agents.noLimitsCodex"))
                        .font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            if statusLineMissing {
                NookGhostButton(title: tr("button.link")) { app.connect(profile) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
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
        switch profile.kind {
        case .claude:
            guard let usage = app.hub.subscriptionUsage(for: profile) else { return [] }
            return [
                usage.fiveHour.map { UsageLimit(label: tr("agents.fiveHour"), percent: $0.effectivePercent, resetsAt: $0.resetsAt) },
                usage.sevenDay.map { UsageLimit(label: tr("agents.week"), percent: $0.effectivePercent, resetsAt: $0.resetsAt) }
            ].compactMap { $0 }
        case .gemini:
            return []
        case .codex:
            guard profile.isDefault, let snapshot = app.codex.snapshot else { return [] }
            return [
                snapshot.fiveHour.map { UsageLimit(label: tr("agents.fiveHour"), percent: Double($0.percent()), resetsAt: $0.resetsAt) },
                snapshot.weekly.map { UsageLimit(label: tr("agents.week"), percent: Double($0.percent()), resetsAt: $0.resetsAt) }
            ].compactMap { $0 }
        }
    }

    private func plan(for profile: AgentProfile) -> String {
        if let plan = app.history.profileAccounts[profile.id]?.plan, !plan.isEmpty { return plan }
        if profile.kind == .codex, profile.isDefault, let raw = app.codex.snapshot?.planType, !raw.isEmpty {
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
        return ""
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

private struct LimitCard: View {
    let limit: UsageLimit

    var body: some View {
        let color = AgentFormat.color(percent: limit.percent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(NookTheme.mono(15, .semibold))
                    .foregroundStyle(color)
            }
            Bar(fraction: limit.percent / 100, color: color)
            Text(AgentFormat.reset(limit.resetsAt) ?? tr("agents.spaceEnough"))
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(NookTheme.font(11.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
            Text(value)
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(detail)
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }
}

/// Daily token usage over the past week as seven bars.
private struct DayBars: View {
    let days: [(day: Date, tokens: Int)]
    let color: Color

    var body: some View {
        let peak = max(1, days.map { $0.tokens }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days.indices, id: \.self) { index in
                let entry = days[index]
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(entry.tokens > 0 ? color.opacity(index == days.count - 1 ? 1 : 0.6) : NookTheme.line2)
                        .frame(width: 10, height: max(3, 40 * CGFloat(entry.tokens) / CGFloat(peak)))
                    Text(AgentFormat.weekdayLetter(entry.day))
                        .font(NookTheme.font(9.5))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .help("\(TokenTally.format(entry.tokens)) tokens")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 74)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
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

/// An account in the list: name, email (or missing requirements), and quota utilization.
private struct ProfileRow: View {
    let name: String
    let detail: String
    let warning: Bool
    let isDefault: Bool
    let highest: Double?
    let color: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(name)
                        .font(NookTheme.font(12.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(color)
                            .help(tr("agents.defaultAccount"))
                    }
                    Spacer(minLength: 4)
                    if let highest {
                        Text("\(Int(highest.rounded()))%")
                            .font(NookTheme.mono(10.5, .medium))
                            .foregroundStyle(AgentFormat.color(percent: highest))
                    }
                }
                Text(detail)
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(warning ? NookTheme.amber : NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 15)
                if let highest {
                    Bar(fraction: highest / 100, color: AgentFormat.color(percent: highest))
                        .padding(.leading, 15)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color(hex: 0x18181E) : (hovering ? Color(hex: 0x121216) : NookTheme.field))
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? color.opacity(0.4) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Sessions" or "Accounts" tab at the top, with a badge counting active sessions.
private struct ModeButton: View {
    let title: String
    let badge: (String, Color)?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(selected ? NookTheme.ink : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                if let badge {
                    Text(badge.0)
                        .font(NookTheme.mono(10.5, .semibold))
                        .foregroundStyle(selected ? NookTheme.ink : badge.1)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(selected ? NookTheme.ink.opacity(0.1) : badge.1.opacity(0.16)))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(selected ? NookTheme.paper : (hovering ? Color(hex: 0x18181E) : NookTheme.field)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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

/// Workspace sessions that are currently working or just finished, clickable for navigation.
private struct WorkspaceRunsSection: View {
    @ObservedObject var workspace: WorkspaceManager
    let open: (UUID) -> Void

    var body: some View {
        let recent = workspace.runs
            .filter { !$0.archived && ($0.status.isActive || Date().timeIntervalSince($0.updatedAt) < 6 * 3600) }
            .sorted { ($0.status.isActive ? 0 : 1, $1.updatedAt) < ($1.status.isActive ? 0 : 1, $0.updatedAt) }
            .prefix(5)
        if !recent.isEmpty {
            SectionHeader(title: tr("ws.windowTitle"), trailing: nil)
                .padding(.top, 12)
            ForEach(Array(recent)) { run in
                Button { open(run.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: run.status.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(run.status.color)
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
