import SwiftUI

/// Nook's main window: the same tabs as the notch (Nook with home and chat, Agents with every session and its tools,
/// Music while something plays), each with the room of a window. A sidebar on the left switches between them; tasks
/// such as reviewing changes open over the tab, as they do in the notch. While the window is in front, anything that
/// asks for a tab or a task opens here (see `NotchViewModel.routesToWindow`).
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var viewModel = AppModel.shared.viewModel

    var body: some View {
        HStack(spacing: 0) {
            WindowSidebar(viewModel: viewModel, tabs: tabs)
                .frame(width: 216)
            WSHairline()
            VStack(alignment: .leading, spacing: 0) {
                PanelApprovalBar(viewModel: viewModel, tab: viewModel.windowTab, sheet: viewModel.windowSheet,
                                 hub: app.hub, workspace: app.workspace)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 24)
            // Below the title bar, which the content runs under.
            .padding(.top, 40)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WS.background)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            // ⌘1, ⌘2, ⌘3 switch tabs; ⌘N starts a session.
            Group {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    Button("") { select(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Button("") { newSession() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .animation(NookTheme.swap, value: viewModel.windowTab)
        .animation(NookTheme.swap, value: viewModel.windowSheet)
        .sheet(isPresented: $app.showOnboarding) {
            OnboardingView {
                app.settings.onboardingDone = true
                app.showOnboarding = false
            }
        }
        .tint(NookTheme.iris)
        .id(app.settings.accentHex)
        .frame(minWidth: 900, minHeight: 580)
    }

    /// The notch's tabs: Music only while a player is open (or while you are on it).
    private var tabs: [PanelTab] {
        PanelTab.visible(musicAvailable: app.nowPlaying.current != nil || viewModel.windowTab == .music)
    }

    @ViewBuilder
    private var content: some View {
        if let sheet = viewModel.windowSheet {
            NotchSheetView(sheet: sheet, close: { viewModel.windowSheet = nil }) { viewModel.windowSheet = nil }
                .transition(.opacity.combined(with: .offset(y: 6)))
        } else {
            Group {
                switch viewModel.windowTab {
                case .agents: AgentsTab(viewModel: viewModel)
                case .music: MusicTab()
                default: NookChatView(viewModel: viewModel, chat: app.chat, compact: false)
                }
            }
            .id(viewModel.windowTab)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }

    private func select(_ tab: PanelTab) {
        viewModel.windowSheet = nil
        viewModel.windowTab = tab
    }

    private func newSession() {
        viewModel.windowSheet = nil
        viewModel.selectedAgentID = "new"
        viewModel.windowTab = .agents
    }
}

/// The window's sidebar: Nook's name under the traffic lights, the tabs, and at the bottom talking and Settings.
private struct WindowSidebar: View {
    @ObservedObject var viewModel: NotchViewModel
    let tabs: [PanelTab]
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nook")
                .font(NookTheme.font(15, .semibold))
                .foregroundStyle(WS.text)
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
                .accessibilityAddTraits(.isHeader)
            ForEach(tabs) { tab in
                WindowNavRow(title: tab.title, symbol: symbol(tab), badge: badge(tab),
                             selected: viewModel.windowTab == tab && viewModel.windowSheet == nil && !startingSession(tab)) {
                    viewModel.windowSheet = nil
                    viewModel.windowTab = tab
                }
            }
            WindowNavRow(title: tr("agents.newSession"), symbol: "square.and.pencil", badge: 0,
                         selected: viewModel.windowTab == .agents && viewModel.selectedAgentID == "new" && viewModel.windowSheet == nil) {
                viewModel.windowSheet = nil
                viewModel.selectedAgentID = "new"
                viewModel.windowTab = .agents
            }
            .padding(.top, 10)
            Spacer(minLength: 12)
            WindowNavRow(title: tr("button.talkShort"), symbol: "mic", badge: 0, selected: false) {
                viewModel.startListening()
            }
            .help(tr("button.talk"))
            WindowNavRow(title: tr("button.settings"), symbol: "gearshape", badge: 0, selected: false) {
                app.openSettings()
            }
        }
        .padding(.horizontal, 10)
        // Clear of the traffic lights: the sidebar runs up under the title bar.
        .padding(.top, 46)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WS.sidebar)
    }

    /// The new-session line is the selected one while a session is being started.
    private func startingSession(_ tab: PanelTab) -> Bool {
        tab == .agents && viewModel.selectedAgentID == "new"
    }

    private func symbol(_ tab: PanelTab) -> String {
        switch tab {
        case .agents: return "person.2.wave.2"
        case .music: return "music.note"
        default: return "bubble.left.and.bubble.right"
        }
    }

    /// Agents that wait for you, on the Agents tab.
    private func badge(_ tab: PanelTab) -> Int {
        guard tab == .agents else { return 0 }
        return app.activeAgents.filter { $0.status == .waiting || $0.approvalID != nil }.count
    }
}

/// One line in the window's sidebar: symbol, name and, when something waits, a count.
private struct WindowNavRow: View {
    let title: String
    let symbol: String
    let badge: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? WS.text : WS.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(NookTheme.font(13.5, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? WS.text : WS.text.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(NookTheme.font(10.5, .bold))
                        .foregroundStyle(NookTheme.ink)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(NookTheme.amber))
                        .help(tr("ws.sidebar.pendingHelp"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? WS.selected : (hovering ? WS.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
