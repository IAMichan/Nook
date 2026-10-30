import SwiftUI

/// Split view: a second tab beside the one you are on (the Nook chat, Agents, Chats or Music), so you can keep an eye on
/// your chats or the music while you work in another tab. Chosen with the button next to the bell, remembered, and the
/// same in the notch and the main window. The tab you are on does not show a second time beside itself.
enum PanelSplitChoice {
    /// The tab shown beside the current one (`PanelTab.rawValue`), empty while split view is off.
    static let key = "nook.panel.split"
    /// How wide the second tab is: drag the line beside it, double-click it to reset.
    static let widthKey = "nook.panel.splitWidth"
    /// The tabs that can sit beside another one.
    static let choices: [PanelTab] = [.chat, .agents, .inbox, .music]

    /// The tab beside `current` for the stored choice, nil while split view is off or the choice is the tab itself.
    static func side(_ stored: String, current: PanelTab) -> PanelTab? {
        guard let tab = PanelTab(rawValue: stored), choices.contains(tab), !same(tab, current) else { return nil }
        return tab
    }

    /// The tab to show for a request to open `tab` while `current` is the main tab: `current` itself when `tab` already
    /// shows beside it, so a chat (or session, or conversation) opened from search or a notice opens in that pane
    /// instead of taking the whole panel and closing split view.
    static func landing(_ tab: PanelTab, current: PanelTab, stored: String? = nil) -> PanelTab {
        let stored = stored ?? UserDefaults.standard.string(forKey: key) ?? ""
        guard let side = side(stored, current: current), same(side, tab) else { return tab }
        return current
    }

    /// Nook and its chat are one tab.
    static func same(_ a: PanelTab, _ b: PanelTab) -> Bool {
        let nook: Set<PanelTab> = [.nook, .chat, .connect, .shelf]
        return a == b || (nook.contains(a) && nook.contains(b))
    }

    static func symbol(_ tab: PanelTab) -> String {
        switch tab {
        case .nook, .chat, .connect, .shelf: return "sparkles"
        case .agents: return "terminal"
        case .inbox: return "bubble.left.and.bubble.right"
        case .music: return "music.note"
        }
    }
}

/// The split view button in the panel's header, next to the bell: lit while a second tab shows, and a short list to
/// pick which one (or none).
struct PanelSplitButton: View {
    let current: PanelTab
    @AppStorage(PanelSplitChoice.key) private var split = ""
    @State private var open = false

    var body: some View {
        let on = PanelSplitChoice.side(split, current: current) != nil
        NookIconButton(systemName: on ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                       label: tr("split.title"), size: 30) { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    DropdownHeader(title: tr("split.header"))
                    ForEach(PanelSplitChoice.choices) { tab in
                        DropdownRow(symbol: PanelSplitChoice.symbol(tab), title: tab.title,
                                    chosen: split == tab.rawValue,
                                    disabledReason: PanelSplitChoice.same(tab, current) ? tr("split.onTab") : nil) {
                            withAnimation(NookTheme.reveal) { split = tab.rawValue }
                        }
                    }
                    DropdownDivider()
                    DropdownRow(symbol: "rectangle", title: tr("split.off"), chosen: split.isEmpty) {
                        withAnimation(NookTheme.reveal) { split = "" }
                    }
                }
                .padding(NookTheme.Spacing.xs)
                .frame(width: 220, alignment: .leading)
                .background(DropdownStyle.panel)
                .environment(\.closeDropdown, { open = false })
            }
    }
}

/// The second tab of split view, on the right of the current one: its name, a button that swaps it with the main tab,
/// and the close button, over the tab itself.
struct PanelSplitPane: View {
    @ObservedObject var viewModel: NotchViewModel
    let tab: PanelTab
    let inWindow: Bool
    /// Makes this the main tab, and the main tab the one beside it.
    let swap: () -> Void
    @EnvironmentObject private var app: AppModel
    @AppStorage(PanelSplitChoice.key) private var split = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            SidePanelHeader(closeHelp: tr("split.close"), close: { withAnimation(NookTheme.reveal) { split = "" } }) {
                SidePanelTitle(symbol: PanelSplitChoice.symbol(tab), title: tab.title)
            } actions: {
                ToolbarIconButton("arrow.left.arrow.right", tr("split.swap"), swap)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The tab as it shows on its own, without the footer the main tab already has.
    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nook, .chat, .connect, .shelf: NookChatView(viewModel: viewModel, chat: app.chat, compact: true)
        case .agents: AgentsTab(viewModel: viewModel)
        case .inbox: ChatsTab(viewModel: viewModel, inWindow: inWindow)
        case .music: MusicTab()
        }
    }
}
