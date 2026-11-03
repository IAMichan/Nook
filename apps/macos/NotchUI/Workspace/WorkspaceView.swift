import SwiftUI

/// Nook's main window: the open notch with the room of a window. The same panel (Nook with home and chat, Agents with
/// every session and its tools, Music while something plays), with Nook and his task ring next to the same tabs, and
/// tasks such as reviewing changes opening over the tab as they do in the notch. While the window is open, anything that
/// asks for a tab or a task (View on a notch card too) opens here and brings it forward (see `NotchViewModel.routesToWindow`).
struct WorkspaceView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var viewModel = AppModel.shared.viewModel
    /// A chat's video or photo shown over the whole window.
    @StateObject private var mediaStage = ChatMediaStage()
    /// The tab draws the sidebar along the window's left edge (`PanelSidebarTop`): no margin on that side, and Nook stands
    /// small in the title bar's row, just past the traffic lights, instead of beside the header.
    @State private var sidebarShown = false

    var body: some View {
        let orb = sidebarShown ? PanelSidebarMetrics.orb : PanelOrb.panelSize
        ZStack(alignment: .topLeading) {
            PanelView(viewModel: viewModel, tab: viewModel.windowTab, headerInset: PanelOrb.headerInset, inWindow: true)
            // Drawn here, over the panel, and not inside the sidebar's column: that column clips, and cut off his ring
            // and the labels it shows on hover.
            PanelOrb(viewModel: viewModel, mood: viewModel.mood(for: viewModel.windowTab), size: orb, inWindow: true)
                .offset(x: sidebarShown ? PanelSidebarMetrics.orbLeading : 0,
                        y: sidebarShown ? (PanelSidebarMetrics.titleBand - orb) / 2 - PanelSidebarMetrics.contentTop
                            : (PanelView.headerHeight - orb) / 2)
        }
        .onPreferenceChange(PanelSidebarShown.self) { shown in
            if sidebarShown != shown { sidebarShown = shown }
        }
        // The notch's margins, or with the sidebar none on its side and less elsewhere. On top the content runs up into
        // the title bar's row (its empty toolbar puts the traffic lights in the middle of a 52 pt band): with the sidebar
        // its head fills that row and a session's header is centered on it; without, the header starts below it.
        .padding(.top, sidebarShown ? PanelSidebarMetrics.contentTop : WindowLayout.belowTitleBar)
        .padding(.leading, sidebarShown ? 0 : 28)
        .padding(.trailing, sidebarShown ? 20 : 28)
        .padding(.bottom, sidebarShown ? 16 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        // The row with the traffic lights acts as the title bar where no content lies on it, so a double-click there
        // zooms the window and a drag moves it, as in every other Mac app.
        .background(alignment: .top) {
            // Measured from the window's top, as the content now is: the title bar's row, and without the sidebar the
            // room under it down to the header.
            WindowTitleBarArea()
                .frame(height: sidebarShown ? PanelSidebarMetrics.titleBand : WindowLayout.belowTitleBar)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
        }
        .background(NookTheme.notch.ignoresSafeArea())
        .chatMediaStage(mediaStage)
        .background {
            // ⌘1, ⌘2, ⌘3 switch tabs.
            Group {
                ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                    Button("") { select(tab) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // ⌘N starts a session, unless a list on screen starts its own kind (a new Nook chat).
        .keyCommand("session.new", priority: -1) { newSession() }
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
        // Animated here and not on the window: an animation on the root sprang everything that changes with the tab
        // (the footer, the bars around the content), and the tab laid out again on every frame of it.
        withAnimation(NookTheme.swap) { viewModel.windowTab = tab }
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
    /// Nook sits on the header row's center, as in the notch: lifted above it, his ring ran into the traffic lights.
    /// The content below starts under his ring (`PanelOrb.belowHeader`).
    /// Measured from the window's top: past the title bar's row (`PanelSidebarMetrics.titleBand`) with the margin
    /// Nook's ring needs.
    static let belowTitleBar: CGFloat = 48
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
