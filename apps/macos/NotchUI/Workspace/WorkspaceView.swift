import SwiftUI

/// Nook's main window: the open notch with the room of a window. The same panel (Nook with home and chat, Agents with
/// every session and its tools, Music while something plays), with Nook and his task ring next to the same tabs, and
/// tasks such as reviewing changes opening over the tab as they do in the notch. While the window is in front, anything
/// that asks for a tab or a task opens here (see `NotchViewModel.routesToWindow`).
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var viewModel = AppModel.shared.viewModel

    var body: some View {
        let orb = PanelOrb.panelSize
        ZStack(alignment: .topLeading) {
            PanelView(viewModel: viewModel, tab: viewModel.windowTab, headerInset: PanelOrb.headerInset, inWindow: true)
            PanelOrb(viewModel: viewModel, mood: viewModel.mood(for: viewModel.windowTab), size: orb, inWindow: true)
                .offset(y: (PanelView.headerHeight - orb) / 2)
        }
        // The notch's margins. On top, the title bar with the traffic lights takes the place of the camera's strip: the
        // content stays in the safe area below it (whatever height the system gives the title bar), and only the black
        // runs up under it. Adding the title bar's height by hand on top of the safe area left a wide empty band.
        .padding(.top, WindowLayout.belowTitleBar)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NookTheme.notch.ignoresSafeArea())
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

private enum WindowLayout {
    /// The room between the title bar and the header row: enough for Nook and his task ring, who stand taller than the
    /// row, to stay clear of the traffic lights.
    static let belowTitleBar: CGFloat = 16
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
