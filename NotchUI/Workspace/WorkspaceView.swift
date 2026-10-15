import SwiftUI

/// The three parts of Nook's main window: the chat, the agents, and the workspace with its tools.
/// (Usage moved to Settings › Usage, so every function has one place.)
enum WorkspacePane: String, CaseIterable, Identifiable {
    case chat, sessions, workspace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return tr("main.chat")
        case .sessions: return tr("main.agents")
        case .workspace: return tr("main.workspace")
        }
    }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .sessions: return "person.2.wave.2"
        case .workspace: return "hammer"
        }
    }
}

/// Nook's main window. Chat: all conversations. Agents: sidebar of sessions, the session, and its inspector.
/// Workspace: terminals, the browser and worktrees.
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @State private var pane: WorkspacePane = .sessions
    @State private var showInspector = true
    /// Whether the inspector may be shown right now. It is switched off before the sidebar collapses and back on after the
    /// sidebar is back, so the window never has to change two columns in one layout pass (that loops).
    @State private var inspectorAllowed = true
    @State private var showNewSession = false
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            WorkspaceSidebar(pane: $pane, showNewSession: $showNewSession)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WS.background)
                .inspector(isPresented: inspectorBinding) {
                    if let run = workspace.run(workspace.selectedRunID) {
                        RunInspector(runID: run.id)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                    } else {
                        Color.clear.inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                    }
                }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet { id in
                pane = .sessions
                workspace.selectedRunID = id
            }
        }
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView {
                app.settings.onboardingDone = true
                app.showOnboarding = false
            }
        }
        .preferredColorScheme(.dark)
        .tint(NookTheme.iris)
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .nookWorkspaceNewSession)) { _ in
            pane = .sessions
            showNewSession = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookMainWindowPane)) { note in
            if let raw = note.object as? String, let target = WorkspacePane(rawValue: raw) { pane = target }
        }
        .onAppear {
            app.history.refresh()
            if workspace.selectedRunID == nil {
                workspace.selectedRunID = workspace.runs.first { !$0.archived }?.id
            }
            columns = pane == .sessions ? .all : .detailOnly
        }
        .onChange(of: workspace.selectedRunID) { _, id in
            if id != nil && pane != .sessions && pane != .chat { pane = .sessions }
            if id != nil { app.selectedExternalSession = nil }
        }
        // The session list belongs to Agents; Chat has its own list of Nooks, Workspace its own tabs.
        .onChange(of: pane) { _, new in
            Task { @MainActor in
                if new == .sessions {
                    columns = .all
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    inspectorAllowed = pane == .sessions
                } else {
                    inspectorAllowed = false
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if pane == new { columns = .detailOnly }
                }
            }
        }
    }

    /// Inspector accompanies session view; remains closed for Worktrees and Usage tabs.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && inspectorAllowed && pane == .sessions && workspace.selectedRunID != nil },
            set: { newValue in
                // SwiftUI writes false while the inspector is unavailable; don't let that overwrite the user's choice.
                if pane == .sessions && workspace.selectedRunID != nil { showInspector = newValue }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .sessions:
            if let id = workspace.selectedRunID, workspace.run(id) != nil {
                RunDetailView(runID: id)
                    .id(id)
            } else if let key = app.selectedExternalSession, let selection = app.sessionSelection(key) {
                AgentSessionDetail(selection: selection)
                    .id(key)
                    .padding(20)
            } else {
                WSEmptyState(
                    symbol: "sparkles.rectangle.stack",
                    title: workspace.runs.isEmpty ? tr("ws.empty.first.title") : tr("ws.empty.none.title"),
                    message: workspace.runs.isEmpty ? tr("ws.empty.first.message") : tr("ws.empty.none.message"),
                    action: (tr("ws.newSession"), { showNewSession = true })
                )
            }
        case .chat:
            NookChatView(viewModel: app.viewModel, chat: app.chat, compact: false)
                .padding(20)
                .background(NookTheme.notch)
        case .workspace:
            WorkbenchView()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showNewSession = true
            } label: {
                Label(tr("ws.newSession"), systemImage: "square.and.pencil")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help(tr("ws.newSession.help"))
        }
        ToolbarItem(placement: .principal) {
            Picker(tr("ws.pane.label"), selection: $pane) {
                ForEach(WorkspacePane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
            .frame(width: 330)
            .background {
                // ⌘1, ⌘2, ⌘3 switch views.
                ForEach(Array(WorkspacePane.allCases.enumerated()), id: \.element) { index, item in
                    Button("") { pane = item }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0)
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label(tr("ws.inspector.toggle"), systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(tr("ws.inspector.toggle"))
            .disabled(pane != .sessions)
        }
    }
}

/// Display name for an account: custom label, organization name, or "Personal".
enum AccountLabel {
    @MainActor
    static func name(_ profile: AgentProfile, app: AppModel) -> String {
        if !profile.label.isEmpty { return profile.label }
        let account = app.history.profileAccounts[profile.id]
        if let org = account?.organization, !org.isEmpty { return org }
        return tr("agents.personal")
    }

    /// "Work · user@… " or "Work (not logged in)".
    @MainActor
    static func line(_ profile: AgentProfile, app: AppModel) -> String {
        let name = name(profile, app: app)
        guard let account = app.history.profileAccounts[profile.id] else {
            return name + " (" + tr("agents.notLoggedInShort") + ")"
        }
        return account.name == name ? name : "\(name) · \(account.name)"
    }
}
