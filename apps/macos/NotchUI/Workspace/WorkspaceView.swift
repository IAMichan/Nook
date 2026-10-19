import SwiftUI

/// The two parts of Nook's main window: the chat and the agents. Terminals, the browser and worktrees are tools of the
/// agents. (Usage moved to Settings › Usage, so every function has one place.)
enum WorkspacePane: String, CaseIterable, Identifiable {
    case chat, sessions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chat: return tr("main.chat")
        case .sessions: return tr("main.agents")
        }
    }
    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .sessions: return "person.2.wave.2"
        }
    }
}

/// What the Agents part of the window shows next to the session list: the selected session, or one of its tools.
/// The terminal opens on the selected session's folder; the browser and worktrees are shared.
enum WindowTool: String, CaseIterable, Identifiable {
    case conversation, terminal, browser, worktrees
    var id: String { rawValue }
    var title: String { tr("ws.tool." + rawValue) }
    var symbol: String {
        switch self {
        case .conversation: return "text.bubble"
        case .terminal: return "terminal"
        case .browser: return "safari"
        case .worktrees: return "arrow.triangle.branch"
        }
    }

    init(_ tool: WorkbenchTool) {
        switch tool {
        case .terminals: self = .terminal
        case .browser: self = .browser
        case .worktrees: self = .worktrees
        }
    }
}

/// Nook's main window. Chat: all conversations. Agents: sidebar of sessions, then the session with its inspector, or
/// one of its tools: a terminal in its folder, the browser, the worktrees.
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @State private var pane: WorkspacePane = .sessions
    @State private var showInspector = true
    @State private var showNewSession = false
    @State private var tool: WindowTool = .conversation
    /// A terminal was just opened on request: keep it in front instead of the selected session's.
    @State private var keepOpenedTerminal = false

    var body: some View {
        // Plain stacks instead of NavigationSplitView + .inspector: the split view's child controllers kept reporting a new
        // min/max size to each other on every constraints pass, which aborts with "needing another Update Constraints in
        // Window pass" when switching pane or opening a sheet.
        HStack(spacing: 0) {
            if pane == .sessions {
                WorkspaceSidebar(pane: $pane, showNewSession: $showNewSession)
                    .frame(width: 264)
                WSHairline()
            }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WS.background)
            if showInspector, pane == .sessions, tool == .conversation, let run = workspace.run(workspace.selectedRunID) {
                WSHairline()
                RunInspector(runID: run.id)
                    .frame(width: 320)
            }
        }
        .toolbar { toolbar }
        .background {
            // ⌘N starts a session from anywhere in the window; the visible button is in the sidebar.
            Button("") {
                pane = .sessions
                showNewSession = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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
            // "workspace" was the third part before its tools moved to Agents.
            if let raw = note.object as? String, let target = WorkspacePane(rawValue: raw == "workspace" ? "sessions" : raw) { pane = target }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nookWorkbenchTool)) { note in
            guard let raw = note.object as? String, let target = WorkbenchTool(rawValue: raw) else { return }
            pane = .sessions
            let next = WindowTool(target)
            if next == .terminal && tool != .terminal { keepOpenedTerminal = true }
            tool = next
        }
        .onChange(of: tool) { _, new in
            if new == .terminal && !keepOpenedTerminal { showSessionTerminal() }
            keepOpenedTerminal = false
        }
        .onChange(of: app.selectedExternalSession) { _, key in
            if tool == .terminal { showSessionTerminal() } else if key != nil { tool = .conversation }
        }
        .onAppear {
            app.history.refresh()
            if workspace.selectedRunID == nil {
                workspace.selectedRunID = workspace.runs.first { !$0.archived }?.id
            }
        }
        .onChange(of: workspace.selectedRunID) { _, id in
            if id != nil { app.selectedExternalSession = nil }
            // Picking a session shows it; on the terminal tool, its terminal.
            if tool == .terminal { showSessionTerminal() } else if id != nil { tool = .conversation }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .sessions where tool == .terminal:
            TerminalsView()
        case .sessions where tool == .browser:
            BrowserView()
        case .sessions where tool == .worktrees:
            WorktreesView()
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
        }
    }

    /// The folder the selected session works in: its worktree for a session Nook runs, the session's folder otherwise.
    private var selectedDirectory: String? {
        if let run = workspace.run(workspace.selectedRunID) { return run.workingDirectory }
        guard let key = app.selectedExternalSession, let selection = app.sessionSelection(key) else { return nil }
        switch selection {
        case .live(let session): return session.cwd.isEmpty ? nil : session.cwd
        case .past(let session): return session.cwd.isEmpty ? nil : session.cwd
        }
    }

    /// On the terminal tool, the selected session's terminal is the one in front: an existing one in its folder, or a
    /// new one there.
    private func showSessionTerminal() {
        guard let directory = selectedDirectory else { return }
        let store = TerminalStore.shared
        if let existing = store.sessions(in: directory).last {
            if !store.sessions(in: directory).contains(where: { $0.id == store.selected }) { store.selected = existing.id }
        } else {
            store.open(in: directory)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
            if pane == .sessions {
                Picker(tr("ws.tool.label"), selection: $tool) {
                    ForEach(WindowTool.allCases) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help(tr("ws.tool.label"))
            }
            Button {
                showInspector.toggle()
            } label: {
                Label(tr("ws.inspector.toggle"), systemImage: "sidebar.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(tr("ws.inspector.toggle"))
            .disabled(pane != .sessions || tool != .conversation)
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
