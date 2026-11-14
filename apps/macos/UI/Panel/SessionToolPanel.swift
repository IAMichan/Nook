import AppKit
import Combine
import SwiftUI

/// One tab of a tool panel: a tool, or one of the Pull request or browser tabs (there can be several of each).
enum SessionTab: Hashable {
    case tool(SessionTool)
    case pullRequest(UUID)
    case browser(UUID)
}

/// A tool panel beside or under a session: its open tools as tabs, + to open another, the button that closes it, and
/// the tool in view (or the list of tools while none is open). It sits flat on the notch, not as a card.
struct SessionToolPanel: View {
    let directory: String
    let runID: UUID?
    let tool: SessionTool
    /// Whether it takes the whole workbench; nil for the bottom panel, and while it must cover the conversation anyway.
    var maximized: Binding<Bool>? = nil
    let tabs: [SessionTool]
    let pullRequest: PullRequestOpenRequest?
    let pullRequestTabs: [SidePullRequestTab]
    let activePullRequest: UUID?
    let outputs: [SessionOutput]
    @Binding var outputSelection: String?
    let outputsFresh: Bool
    let subagents: [SubagentInfo]
    let commands: [BackgroundCommandInfo]
    let subagentsFresh: Bool
    /// The agent's turns and what the Changes tab shows of them or of git.
    let turns: [TurnDiff]
    @Binding var diffSelection: TurnDiffSelection
    let loadDiff: ((TurnDiff, [TurnDiff.File], DiffReadOptions) async throws -> String)?
    let closeHelp: String
    let show: (SessionTool) -> Void
    let selectPullRequest: (UUID) -> Void
    /// Opens a Pull request tab beside the session, on this pull request or (nil) on the list to pick one.
    let openPullRequest: (PullRequestOpenRequest?) -> Void
    /// The active tab's pull request was read again.
    let updatePullRequest: (PullRequestOpenRequest) -> Void
    /// The active tab goes back to the list to pick another.
    let showPullRequestList: () -> Void
    let closeTab: (SessionTab) -> Void
    let close: () -> Void
    /// The sub-thread the Sub-thread tab shows, live with its own composer, and the way to open it as the main view.
    var subThread: UUID? = nil
    var openSubThreadHere: (UUID) -> Void = { _ in }
    /// A command the agent runs, opened from the conversation: the Terminal tab shows it in place of your shells.
    var console: CommandConsoleRef? = nil
    /// Shows another command of the agent in the Terminal tab: the one it runs now, when you ask for it.
    var showConsole: (UUID) -> Void = { _ in }
    var closeConsole: () -> Void = {}
    /// The tools pinned to the front of the tab row, what dragging one tab onto another does, and the pin in a tab's menu.
    var pinned: Set<SessionTool> = []
    var moveTab: (_ moved: SessionTool, _ onto: SessionTool) -> Void = { _, _ in }
    var togglePin: (SessionTool) -> Void = { _ in }
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @ObservedObject private var files = FileViewerStore.shared
    /// Says when this session's browser was started.
    @ObservedObject private var browsers = SessionBrowsers.shared
    /// The browser's tabs with their titles, and the one in view, once the browser was started (it is not started for it).
    @State private var browserTabs: [BrowserStore.Tab] = []
    @State private var browserActive: UUID?
    /// The panel still slides in: a pull request page it opens on waits with its full page until it is in place.
    @State private var opening = true

    var browserSession: BrowserSession { BrowserSession(run: runID, directory: directory) }
    /// This session's browser, if it was started.
    private var startedBrowser: BrowserStore? { browsers.existing(browserSession) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if tool == .terminal, console == nil { SidePanelToolbar { SessionTerminalBar(directory: directory) } }
            if tool == .browser, !directory.isEmpty {
                let browser = browsers.store(browserSession)
                DevServerStrip(directory: directory, browser: browser).id(ObjectIdentifier(browser))
            }
            Group {
                switch tool {
                case .picker:
                    SessionToolPicker(directory: directory) { launch($0) }
                case .terminal:
                    if let console {
                        LiveCommandConsole(timelines: workspace.timelineChanges(for: console.run), workspace: workspace, console: console,
                                           show: showConsole, close: closeConsole)
                    } else {
                        SessionTerminalsView(directory: directory).id(directory)
                    }
                case .outputs: SessionOutputsPanel(outputs: outputs, selection: $outputSelection)
                case .subagents: SessionSubagentsPanel(agents: subagents, commands: commands)
                case .changes:
                    // A session on another machine: git is there, and only its own review reads it (over ssh).
                    if let runID, workspace.run(runID)?.isRemote == true, diffSelection.source.isGit {
                        ChangesSheet(runID: runID, initialFile: nil, onClose: close).id(runID)
                    } else {
                        TurnDiffPanel(turns: turns, selection: $diffSelection, directory: directory.isEmpty ? nil : directory,
                                      runID: runID, load: loadDiff)
                            .id(directory)
                    }
                case .pullRequest:
                    if let pullRequest {
                        // The page's own top bar starts with the arrow back to the list to pick another, so there is no
                        // extra row above it.
                        let listed = PullRequestStore.shared.accounts.first { $0.id == pullRequest.account }
                            .map { $0.reviews + $0.mine + $0.watched } ?? []
                        PullRequestDetailView(accountID: pullRequest.account, item: pullRequest.item,
                                              stack: PullRequestStack.stack(of: pullRequest.item, in: listed) ?? [],
                                              stackHistory: PullRequestStack.history(of: pullRequest.item, in: listed) ?? [],
                                              onOpenPullRequest: { openPullRequest(PullRequestOpenRequest(account: pullRequest.account, item: $0)) },
                                              onUpdate: { updated in
                            updatePullRequest(PullRequestOpenRequest(account: pullRequest.account, item: updated))
                        }, onBack: showPullRequestList, waitsForPanel: opening, focus: pullRequest.focus)
                            .id(pullRequest.account + " " + pullRequest.item.id)
                    } else {
                        SidePanelPullRequestPicker(directory: directory, runID: runID) { openPullRequest($0) }
                    }
                case .artifact:
                    SessionArtifactPanel()
                case .file:
                    SessionFilePanel(directory: directory)
                case .subThread:
                    if let subThread {
                        // The whole session: its transcript and its own composer, to answer its questions right here.
                        AgentRunPanel(workspace: workspace, timelines: workspace.timelineChanges(for: subThread), runID: subThread,
                                      headerAccessory: AnyView(ToolbarIconButton("arrow.up.forward.square", tr("ws.subthread.openHere")) {
                                          openSubThreadHere(subThread)
                                      }))
                            .id(subThread)
                    } else {
                        SessionToolPicker(directory: directory) { launch($0) }
                    }
                default:
                    let browser = browsers.store(browserSession)
                    // Its own view for each browser: it counts itself as showing that browser.
                    BrowserView(store: browser).id(ObjectIdentifier(browser))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // What the agent opened here is in view now, also when it opens more while you look.
        .onAppear { bridge.markSeen(directory, tool.rawValue) }
        .task {
            try? await Task.sleep(for: NookTheme.tabSettle)
            opening = false
        }
        .onChange(of: tool) { _, next in bridge.markSeen(directory, next.rawValue) }
        .onChange(of: bridge.unseen) { _, _ in bridge.markSeen(directory, tool.rawValue) }
        // Another session without a browser shows none of the last one's tabs.
        .onChange(of: startedBrowser.map(ObjectIdentifier.init)) { _, started in
            if started == nil {
                browserTabs = []
                browserActive = nil
            }
        }
        .onReceive(startedBrowser?.$tabs.eraseToAnyPublisher() ?? Empty<[BrowserStore.Tab], Never>().eraseToAnyPublisher()) {
            browserTabs = $0
        }
        .onReceive(startedBrowser?.$page.map(\.id).eraseToAnyPublisher() ?? Empty<UUID, Never>().eraseToAnyPublisher()) {
            browserActive = $0
        }
    }

    /// The open tabs, + right after them, and the button that closes the panel. The
    /// tabs scroll sideways when they do not fit, so the close button always stays in view.
    private var header: some View {
        SidePanelTabBar(items: tabs.flatMap(tabItems).map(pinnedMark), selected: selectedTab, onSelect: selectTab, onClose: closeTab,
                        onMove: { moved, onto in moveTab(tool(of: moved), tool(of: onto)) },
                        onTogglePin: { togglePin(tool(of: $0)) }) {
            addMenu
        } trailing: {
            if let maximized {
                ToolbarIconButton(maximized.wrappedValue ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tr(maximized.wrappedValue ? "agents.tool.restore" : "agents.tool.maximize")) {
                    maximized.wrappedValue.toggle()
                }
            }
            SidePanelCloseButton(help: closeHelp, action: close)
        }
    }

    /// The tool a tab belongs to: a pull request or a browser tab is one of its tool's tabs, and pins and moves with it.
    private func tool(of tab: SessionTab) -> SessionTool {
        switch tab {
        case .tool(let item): return item
        case .pullRequest: return .pullRequest
        case .browser: return .browser
        }
    }

    private func pinnedMark(_ item: SidePanelTabItem<SessionTab>) -> SidePanelTabItem<SessionTab> {
        var marked = item
        marked.pinned = pinned.contains(tool(of: item.value))
        return marked
    }

    /// The tab in view: a Pull request tab by its own id, as there can be several.
    private var selectedTab: SessionTab {
        if tool == .pullRequest, let active = activePullRequest ?? pullRequestTabs.first?.id { return .pullRequest(active) }
        if tool == .browser, let active = browserActive, browserTabs.contains(where: { $0.id == active }) { return .browser(active) }
        return .tool(tool)
    }

    private func selectTab(_ tab: SessionTab) {
        switch tab {
        case .tool(let item): show(item)
        case .pullRequest(let id): selectPullRequest(id)
        case .browser(let id):
            browsers.store(browserSession).select(id)
            show(.browser)
        }
    }

    /// The tabs of a tool: one, or for the Pull request tool one for each pull request (or list) open, and for the
    /// browser one for each of its tabs, followed by + for another.
    private func tabItems(_ item: SessionTool) -> [SidePanelTabItem<SessionTab>] {
        if item == .browser { return browserTabItems }
        guard item == .pullRequest, !pullRequestTabs.isEmpty else { return [tabItem(item)] }
        return pullRequestTabs.map { tab in
            let request = tab.request
            let title = request.map { "#\($0.item.number) " + ($0.item.title.isEmpty ? $0.item.repo : $0.item.title) } ?? item.title
            let fresh = item != tool && bridge.hasUnseen(directory, item.rawValue)
            return SidePanelTabItem(value: .pullRequest(tab.id), title: title, icon: AnyView(SidePanelPullRequestIcon(item: request?.item)),
                                    fresh: fresh, help: request.map { $0.item.repo + " #\($0.item.number)" } ?? item.help)
        }
    }

    /// The browser's tabs, each with its page's title; the last one has + right after it for a new browser tab.
    private var browserTabItems: [SidePanelTabItem<SessionTab>] {
        let item = SessionTool.browser
        let fresh = item != tool && bridge.hasUnseen(directory, item.rawValue)
        let add = AnyView(ToolbarIconButton("plus", tr("browser.newTab"), width: 20) {
            browsers.store(browserSession).newTab()
            show(.browser)
        })
        guard !browserTabs.isEmpty else {
            return [SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelSymbol(symbol: "globe")),
                                     fresh: fresh, help: item.help, after: add)]
        }
        return browserTabs.enumerated().map { index, tab in
            SidePanelTabItem(value: .browser(tab.id), title: tab.title.isEmpty ? item.title : tab.title,
                             icon: AnyView(SidePanelSymbol(symbol: "globe")), fresh: fresh && tab.id == browserActive,
                             help: tab.title.isEmpty ? item.help : tab.title,
                             after: index == browserTabs.count - 1 ? add : nil)
        }
    }

    /// A tab with what it shows: the file's name, the name of a tool.
    private func tabItem(_ item: SessionTool) -> SidePanelTabItem<SessionTab> {
        let fresh = item != tool && (item == .outputs ? outputsFresh
            : item == .subagents ? subagentsFresh : bridge.hasUnseen(directory, item.rawValue))
        switch item {
        case .pullRequest:
            return SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelPullRequestIcon(item: nil)),
                                    fresh: fresh, help: item.help)
        case .file:
            let path = files.target?.path
            return SidePanelTabItem(value: .tool(item), title: path.map { ($0 as NSString).lastPathComponent } ?? item.title,
                                    icon: AnyView(SidePanelSymbol(symbol: item.symbol)), fresh: fresh,
                                    help: path.map(AgentPathFormat.tilde) ?? item.help)
        case .subThread:
            let title = subThread.flatMap { workspace.run($0)?.title }.flatMap { $0.isEmpty ? nil : $0 }
            return SidePanelTabItem(value: .tool(item), title: title ?? item.title, icon: AnyView(SidePanelSymbol(symbol: item.symbol)),
                                    fresh: fresh, help: title ?? item.help)
        default:
            return SidePanelTabItem(value: .tool(item), title: item.title, icon: AnyView(SidePanelSymbol(symbol: item.symbol)),
                                    fresh: fresh, help: item.help)
        }
    }

    /// + : the tools to open, each in its own tab (or the tab it already has), in Nook's own dropdown panel.
    /// The tool in view is faintly filled; one the session cannot use says why.
    private var addMenu: some View {
        ComposerDropdown(width: 220) {
            Image(icon: "plus")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        } content: {
            ForEach(SessionTool.launchable, id: \.self) { item in
                DropdownRow(symbol: item.symbol, title: item.title, chosen: item == tool,
                            disabledReason: item.available(in: directory) ? nil : tr("agents.tool.needsFolder")) {
                    launch(item)
                }
            }
        }
        .help(tr("agents.tool.add"))
        .accessibilityLabel(tr("agents.tool.add"))
    }

    /// Opens a tool from the + menu or the list of tools; a pull request opens beside the session, on the list to pick.
    private func launch(_ item: SessionTool) {
        if item == .pullRequest { openPullRequest(nil) } else { show(item) }
    }
}

/// An open panel before any tab: the tools, one row each with the key that opens it.
/// A tool the session cannot use (a terminal or changes without a folder) is dimmed and says why.
private struct SessionToolPicker: View {
    let directory: String
    let onOpen: (SessionTool) -> Void

    var body: some View {
        SidePanelLauncher(title: tr("agents.tool.pick"), items: SessionTool.launchable.map { tool in
            SidePanelLaunch(id: tool.rawValue, symbol: tool.symbol, title: tool.title, key: tool.key,
                            disabledReason: tool.available(in: directory) ? nil : tr("agents.tool.needsFolder")) { onOpen(tool) }
        })
    }
}

/// A tool's mark in its tab.
private struct SidePanelSymbol: View {
    let symbol: String

    var body: some View {
        NookSymbol(symbol, size: 12).font(NookTheme.font(10.5, .medium))
    }
}

/// A pull request's state mark in its tab, in the state's color.
private struct SidePanelPullRequestIcon: View {
    let item: PullRequestItem?

    var body: some View {
        if let item { PullRequestLiveStateIcon(item: item) } else { PullRequestStateIcon(glyph: .open) }
    }
}
