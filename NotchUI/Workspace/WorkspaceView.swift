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
    @State private var showNewSession = false

    var body: some View {
        // Plain stacks instead of NavigationSplitView + .inspector: the split view's child controllers kept reporting a new
        // min/max size to each other on every constraints pass, which aborts with "needing another Update Constraints in
        // Window pass" when switching pane or opening a sheet.
        HStack(spacing: 0) {
            if pane == .sessions {
                WorkspaceSidebar(pane: $pane, showNewSession: $showNewSession)
                    .frame(width: 290)
                Divider()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WS.background)
            if showInspector, pane == .sessions, let run = workspace.run(workspace.selectedRunID) {
                Divider()
                RunInspector(runID: run.id)
                    .frame(width: 320)
            }
        }
        .toolbar { toolbar }
        // Presented as a native AppKit sheet: SwiftUI's own `.sheet` re-negotiates its presentation window on every layout
        // pass here and aborts with "needing another Update Constraints in Window pass".
        .onChange(of: showNewSession) { _, show in
            guard show else { return }
            WorkspaceWindowController.shared.presentSheet(size: NSSize(width: 660, height: 720), onClosed: { showNewSession = false }) { close in
                NewSessionSheet(onStarted: { id in
                    pane = .sessions
                    workspace.selectedRunID = id
                }, close: close)
                .environmentObject(app)
                .environmentObject(workspace)
                .environmentObject(workspace.settings)
            }
        }
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView {
                app.settings.onboardingDone = true
                app.showOnboarding = false
            }
        }
        .tint(NookTheme.iris)
        .id(app.settings.accentHex)
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
        }
        .onChange(of: workspace.selectedRunID) { _, id in
            if id != nil && pane != .sessions && pane != .chat { pane = .sessions }
            if id != nil { app.selectedExternalSession = nil }
        }
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
