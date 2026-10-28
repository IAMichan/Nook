import SwiftUI

/// The "Coding agents" step of the first-run flow: each agent Nook can run, whether it is installed and signed in, with
/// the one button that gets it there (the same install-and-sign-in flow as Settings › Agents, in a visible Terminal
/// window), the ACP agents you added, and the git folders you worked in recently to add as projects.
struct OnboardingAgentsStep: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared

    /// The agents the step offers by name; any other agent that speaks ACP is added in Settings › Agents.
    static let kinds: [AgentKind] = [.claude, .codex, .gemini, .opencode, .cursor]

    var body: some View {
        OnboardingPage(title: tr("onboarding.agents.title"), detail: tr("onboarding.agents.detail")) {
            VStack(spacing: NookTheme.Spacing.xs) {
                ForEach(Self.kinds) { kind in agentRow(kind) }
                ForEach(CustomAgents.load()) { agent in acpRow(agent) }
            }
            Button(tr("onboarding.agents.addAcp")) { app.openSettings(section: .agents) }
                .buttonStyle(.link)
            projects
        }
        .onAppear { app.history.refresh() }
    }

    // MARK: Agents

    private func state(_ kind: AgentKind) -> AgentReadiness.State {
        let profile = AgentProfile.defaultProfile(kind)
        let signedIn = app.profiles.all.contains { $0.kind == kind && app.history.profileAccounts[$0.id] != nil }
        return AgentReadiness.classify(scanned: !app.history.loading, installed: app.history.executables[kind] != nil,
                                       signedIn: signedIn, connecting: app.agentConnect[profile.id]?.isBusy == true)
    }

    private func agentRow(_ kind: AgentKind) -> some View {
        let state = state(kind)
        let progress = app.agentConnect[AgentProfile.defaultProfile(kind).id]
        return row(agent: kind.name, title: kind.name, detail: detail(state, progress: progress),
                   failed: Self.failed(progress)) {
            switch AgentReadiness.action(for: state) {
            case .install:
                SmallGhostButton(title: tr("onboarding.agents.install")) { app.connect(kind) }
            case .signIn:
                SmallGhostButton(title: tr("onboarding.agents.signIn")) { app.connect(kind) }
            case .none:
                if state == .ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(NookTheme.mint)
                        .accessibilityLabel(tr("onboarding.agents.ready"))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    /// What the row says under the agent's name: the progress of a running install or sign-in first.
    private func detail(_ state: AgentReadiness.State, progress: AgentConnectProgress?) -> String {
        if let progress, progress.isBusy || Self.failed(progress) { return progress.text }
        return tr("onboarding.agents.state." + state.rawValue)
    }

    private static func failed(_ progress: AgentConnectProgress?) -> Bool {
        if case .failed? = progress { return true }
        return false
    }

    private func acpRow(_ agent: CustomAgent) -> some View {
        row(agent: "ACP", title: agent.name, detail: tr("onboarding.agents.acpAdded"), failed: false) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(NookTheme.mint)
                .accessibilityLabel(tr("onboarding.agents.ready"))
        }
    }

    private func row<Trailing: View>(agent: String, title: String, detail: String, failed: Bool,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            AgentLogo(agent: agent, size: 20)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).font(NookTheme.TextStyle.strong).lineLimit(1)
                Text(detail)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(failed ? NookTheme.coral : NookTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: NookTheme.Spacing.md)
            trailing().fixedSize()
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
    }

    // MARK: Projects

    private var candidates: [AgentReadiness.ProjectCandidate] {
        let fm = FileManager.default
        let sessions = app.history.sessions.map { (folder: $0.cwd, date: $0.ended) }
            + app.workspace.runs.map { (folder: $0.projectPath, date: $0.updatedAt) }
        return AgentReadiness.projectCandidates(sessions: sessions, known: ws.recentProjects,
                                                home: fm.homeDirectoryForCurrentUser.path, now: Date(),
                                                gitRoot: { AgentReadiness.gitRoot(of: $0, fileExists: fm.fileExists(atPath:)) })
    }

    @ViewBuilder
    private var projects: some View {
        let list = candidates
        if !list.isEmpty {
            Text(tr("onboarding.projects.title")).font(NookTheme.TextStyle.strong).padding(.top, NookTheme.Spacing.md)
            Text(tr("onboarding.projects.detail")).foregroundStyle(NookTheme.textSecondary)
            VStack(spacing: NookTheme.Spacing.xs) {
                ForEach(list, id: \.path) { candidate in projectRow(candidate) }
            }
        }
    }

    private func projectRow(_ candidate: AgentReadiness.ProjectCandidate) -> some View {
        let added = candidate.added || ws.recentProjects.contains(candidate.path)
        return HStack(spacing: NookTheme.Spacing.lg) {
            Image(systemName: "folder").foregroundStyle(NookTheme.textSecondary).frame(width: 20)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(candidate.name).font(NookTheme.TextStyle.strong)
                Text(AgentPathFormat.tilde(candidate.parent) + " · " + tr("onboarding.projects.sessions", candidate.sessions))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: NookTheme.Spacing.md)
            if added {
                Label(tr("onboarding.projects.added"), systemImage: "checkmark")
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.mint)
            } else {
                // Only remembers the folder as a project (Settings › Workspace's recent projects); nothing runs.
                SmallGhostButton(title: tr("onboarding.projects.add")) { ws.rememberProject(candidate.path) }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
        .help(AgentPathFormat.tilde(candidate.path))
    }
}
