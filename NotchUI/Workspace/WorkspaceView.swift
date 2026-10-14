import SwiftUI

/// Welke weergave de werkruimte rechts toont.
enum WorkspacePane: String, CaseIterable, Identifiable {
    case sessions, worktrees, usage
    var id: String { rawValue }
    var title: String { tr("ws.pane." + rawValue) }
    var symbol: String {
        switch self {
        case .sessions: return "bubble.left.and.text.bubble.right"
        case .worktrees: return "arrow.triangle.branch"
        case .usage: return "chart.bar.xaxis"
        }
    }
}

/// De werkruimte: links projecten en sessies, in het midden de sessie, rechts de details.
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @State private var pane: WorkspacePane = .sessions
    @State private var showInspector = true
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
        .preferredColorScheme(.dark)
        .tint(NookTheme.iris)
        .frame(minWidth: 760, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .nookWorkspaceNewSession)) { _ in showNewSession = true }
        .onAppear {
            app.history.refresh()
            if workspace.selectedRunID == nil {
                workspace.selectedRunID = workspace.runs.first { !$0.archived }?.id
            }
        }
        .onChange(of: workspace.selectedRunID) { _, id in
            if id != nil && pane != .sessions { pane = .sessions }
        }
    }

    /// De inspector hoort bij een sessie; bij Worktrees en Gebruik staat hij dicht.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && pane == .sessions && workspace.selectedRunID != nil },
            set: { showInspector = $0 }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .sessions:
            if let id = workspace.selectedRunID, workspace.run(id) != nil {
                RunDetailView(runID: id)
                    .id(id)
            } else {
                WSEmptyState(
                    symbol: "sparkles.rectangle.stack",
                    title: workspace.runs.isEmpty ? tr("ws.empty.first.title") : tr("ws.empty.none.title"),
                    message: workspace.runs.isEmpty ? tr("ws.empty.first.message") : tr("ws.empty.none.message"),
                    action: (tr("ws.newSession"), { showNewSession = true })
                )
            }
        case .worktrees:
            WorktreesView()
        case .usage:
            UsageView()
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
            .frame(width: 300)
            .background {
                // ⌘1, ⌘2, ⌘3 wisselen van weergave.
                ForEach(Array(WorkspacePane.allCases.enumerated()), id: \.element) { index, item in
                    Button("") { pane = item }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0)
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            DefaultAccountMenu()
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

/// Snel het standaardaccount per agent wisselen. Lopende en eerdere sessies houden hun eigen account.
struct DefaultAccountMenu: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Menu {
            ForEach(RunProvider.allCases) { provider in
                let kind = provider.kind
                let all = app.profiles.profiles(for: kind)
                Section(tr("ws.account.defaultFor", kind.name)) {
                    ForEach(all) { profile in
                        Toggle(isOn: Binding(
                            get: { app.profiles.isPreferred(profile) },
                            set: { if $0 { app.makeDefault(profile) } }
                        )) {
                            Text(AccountLabel.line(profile, app: app))
                        }
                    }
                }
            }
            Divider()
            Button(tr("ws.account.manage")) { app.openSettings(section: .agents) }
        } label: {
            Label(tr("ws.account.menu"), systemImage: "person.crop.circle")
        }
        .help(tr("ws.account.menu.help"))
    }
}

/// Hoe Nook een account noemt: de naam die je koos, of de organisatie, of "Persoonlijk".
enum AccountLabel {
    @MainActor
    static func name(_ profile: AgentProfile, app: AppModel) -> String {
        if !profile.label.isEmpty { return profile.label }
        let account = app.history.profileAccounts[profile.id]
        if let org = account?.organization, !org.isEmpty { return org }
        return tr("agents.personal")
    }

    /// "Werk · michiel@… " of "Werk (niet ingelogd)".
    @MainActor
    static func line(_ profile: AgentProfile, app: AppModel) -> String {
        let name = name(profile, app: app)
        guard let account = app.history.profileAccounts[profile.id] else {
            return name + " (" + tr("agents.notLoggedInShort") + ")"
        }
        return account.name == name ? name : "\(name) · \(account.name)"
    }
}
