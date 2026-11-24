import AppKit
import SwiftUI

/// A tab of a session's side or bottom panel in a window of its own: dragged out of the window, or opened from the tab's
/// menu. It stays with its session, whichever session the main window shows meanwhile: its terminal, its browser, its
/// changes, what its agent produced, and what it hands over lands in that session's composer.
struct DetachedSessionTab: Equatable {
    /// The session in the Agents tab (`PanelViewModel.selectedAgentID`), to go back to it.
    let agentID: String
    let runID: UUID?
    let directory: String
    let tool: SessionTool
    /// The pull request a Pull request tab shows; nil for the list to pick one.
    var pullRequest: PullRequestOpenRequest?
    /// The file a File tab shows: its own, not the one file viewer the side panels share.
    var file: FileTarget?
    /// The sub-thread a Sub-thread tab shows.
    var subThread: UUID?
    /// One window per tool of a session; a pull request or file has one each, as there can be several.
    let key: String

    init(agentID: String, runID: UUID?, directory: String, tool: SessionTool, pullRequest: PullRequestOpenRequest? = nil,
         file: FileTarget? = nil, subThread: UUID? = nil) {
        self.agentID = agentID
        self.runID = runID
        self.directory = directory
        self.tool = tool
        self.pullRequest = pullRequest
        self.file = file
        self.subThread = subThread
        let session = Self.session(run: runID, directory: directory)
        key = SessionTabWindows.single(tool) ? session + "|" + tool.rawValue : session + "|" + tool.rawValue + "|" + UUID().uuidString
    }

    /// The session a tab belongs to, as the workbench names it.
    static func session(run: UUID?, directory: String) -> String {
        (run?.uuidString ?? "") + "|" + directory
    }

    var session: String { Self.session(run: runID, directory: directory) }

    /// Whether this tab shows `tool` of that session in the one place it can be: a terminal follows its folder, as the
    /// shells do (`SessionTerminalsView`); the other tools follow the session.
    func holds(_ tool: SessionTool, run: UUID?, directory: String) -> Bool {
        guard tool == self.tool, SessionTabWindows.single(tool) else { return false }
        if tool == .terminal { return !directory.isEmpty && directory == self.directory }
        return run == runID && directory == self.directory
    }
}

/// What the conversation of a session found its agent produced (`SessionOutputsReport`), kept for the session's tabs in a
/// window of their own: the Outputs, Subagents and Changes tabs read it there. The workbench of the session writes it
/// while it shows; with another session in view it shows what it last had.
@MainActor
final class SessionTabReports: ObservableObject {
    static let shared = SessionTabReports()
    @Published private(set) var reports: [String: SessionOutputsReport] = [:]

    func report(_ report: SessionOutputsReport, session: String) {
        guard SessionTabWindows.shared.hasWindow(session: session), reports[session] != report else { return }
        reports[session] = report
    }

    fileprivate func forget(_ session: String) {
        reports[session] = nil
    }
}

/// The windows of torn-off session tabs. A tool that can be in one place only (a terminal, the browser, a pane worked
/// out from the conversation) leaves the side panel for its window; opening it in the side panel again brings the window
/// forward instead.
@MainActor
final class SessionTabWindows: ObservableObject {
    static let shared = SessionTabWindows()

    @Published private(set) var tabs: [String: DetachedSessionTab] = [:]
    private var windows: [String: NSWindow] = [:]
    private var presences: [String: WindowPresence] = [:]

    /// Whether a tool has one place per session: a terminal or a web view can only be in one window, and the Outputs,
    /// Subagents and Changes tabs would show the same twice. Pull requests, files and sub-threads open as often as you like.
    nonisolated static func single(_ tool: SessionTool) -> Bool {
        switch tool {
        case .terminal, .browser, .changes, .outputs, .subagents: return true
        case .pullRequest, .file, .subThread, .artifact, .conversation, .picker: return false
        }
    }

    /// Whether a tab can have a window of its own: an artifact is Nook's one embedded app, and the list of tools is no tab.
    nonisolated static func detachable(_ tool: SessionTool) -> Bool {
        tool != .artifact && tool != .conversation && tool != .picker
    }

    func hasWindow(session: String) -> Bool {
        tabs.values.contains { $0.session == session }
    }

    /// The window that shows `tool` of this session, if one does.
    func holder(_ tool: SessionTool, run: UUID?, directory: String) -> String? {
        tabs.first { $0.value.holds(tool, run: run, directory: directory) }?.key
    }

    /// Brings forward the window that shows `tool` of this session; false when none does.
    @discardableResult
    func focus(_ tool: SessionTool, run: UUID?, directory: String) -> Bool {
        guard let key = holder(tool, run: run, directory: directory), let window = windows[key] else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Opens `tab` in a window of its own, its top left corner where the drag let go (`at`, on screen), or brings the
    /// window that already shows it forward.
    func open(_ tab: DetachedSessionTab, at point: CGPoint?, report: SessionOutputsReport, app: AppModel) {
        if focus(tab.tool, run: tab.runID, directory: tab.directory) { return }
        tabs[tab.key] = tab
        SessionTabReports.shared.report(report, session: tab.session)
        let window = make(tab.key, app: app)
        windows[tab.key] = window
        place(window, at: point)
        DockPresence.shared.track(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// What the window shows changed (another pull request, another file).
    func update(_ key: String, _ change: (inout DetachedSessionTab) -> Void) {
        guard var tab = tabs[key] else { return }
        change(&tab)
        if tab != tabs[key] { tabs[key] = tab }
    }

    func close(_ key: String) {
        windows[key]?.close()
    }

    /// Closes the window and puts its tab back in its session's side panel, with that session in view.
    func dock(_ key: String, app: AppModel) {
        guard let tab = tabs[key] else { return }
        close(key)
        let viewModel = app.viewModel
        viewModel.selectedAgentID = tab.agentID
        withAnimation(NookTheme.swap) {
            switch tab.tool {
            case .pullRequest:
                viewModel.openSidePullRequest(tab.pullRequest)
            case .file:
                if let file = tab.file { FileViewerStore.shared.open(file) }
                viewModel.sessionTool = .file
            case .subThread:
                viewModel.sideSubThread = tab.subThread
                viewModel.sessionTool = .subThread
            default:
                viewModel.sessionTool = tab.tool
            }
        }
        app.openWindow(continuing: .agents)
    }

    /// Shows the tab's session in the main window, the window staying where it is.
    func showAgent(_ key: String, app: AppModel) {
        guard let tab = tabs[key] else { return }
        app.viewModel.selectedAgentID = tab.agentID
        app.openWindow(continuing: .agents)
    }

    private func make(_ key: String, app: AppModel) -> NSWindow {
        let presence = WindowPresence()
        presences[key] = presence
        let minSize = CGSize(width: 360, height: 320)
        let root = WindowContent(presence: presence, background: NookTheme.canvas, minSize: minSize) {
            SessionTabWindowView(key: key)
        }
            .nookAttention()
            .environmentObject(app)
            .environmentObject(app.workspace)
            .environmentObject(app.workspace.settings)
        let host = WorkspaceHostingView(rootView: root)
        // The window sets its own minSize, as the main window does.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(PanelLayout.tool), height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        NookWindowLook.adopt(window)
        window.title = "Nook · " + (tabs[key]?.tool.title ?? "")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty unified toolbar, as in the main window: the title bar becomes the taller row with the traffic lights
        // in its middle, so the session's name sits beside them.
        window.toolbar = NSToolbar(identifier: "NookSessionTab")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: minSize.width, height: minSize.height)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        presence.follow(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(key) }
        }
        return window
    }

    /// The window is gone: so is its tab, as when you close a tab in the side panel.
    private func closed(_ key: String) {
        presences[key]?.shown = false
        presences[key] = nil
        windows[key] = nil
        guard let tab = tabs.removeValue(forKey: key) else { return }
        if !hasWindow(session: tab.session) { SessionTabReports.shared.forget(tab.session) }
    }

    /// The window's top left corner where the tab was let go, kept on that screen; without a point, beside the window in
    /// front.
    private func place(_ window: NSWindow, at point: CGPoint?) {
        guard let point else {
            if let front = NSApp.keyWindow, front !== window {
                window.setFrameTopLeftPoint(NSPoint(x: front.frame.maxX - window.frame.width - NookTheme.Spacing.xl,
                                                    y: front.frame.maxY - NookTheme.Spacing.xxl))
                window.setFrame(window.constrainFrameRect(window.frame, to: front.screen), display: false)
            } else {
                window.center()
            }
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        window.setFrameTopLeftPoint(NSPoint(x: point.x - NookTheme.Spacing.xxl, y: point.y + NookTheme.Spacing.md))
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }
}

/// The content of a torn-off tab's window: the session's name with the buttons back to the side panel and to the agent,
/// over the tab as the side panel shows it.
private struct SessionTabWindowView: View {
    let key: String
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var windows = SessionTabWindows.shared
    @ObservedObject private var reports = SessionTabReports.shared
    @StateObject private var mediaStage = ChatMediaStage()
    @State private var outputSelection: String?
    @State private var diffSelection = TurnDiffSelection(turn: TurnDiffSelection.branch)
    /// The window's one Pull request tab, with an id that stays.
    @State private var pullRequestTab = SidePullRequestTab(request: nil)

    var body: some View {
        if let tab = windows.tabs[key] {
            content(tab)
                // A session that was deleted takes its tabs with it.
                .onChange(of: tab.runID.map { workspace.run($0) == nil } ?? false) { _, gone in
                    if gone { windows.close(key) }
                }
        } else {
            NookTheme.canvas
        }
    }

    private func content(_ tab: DetachedSessionTab) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                SidePanelTitle(symbol: tab.tool.symbol, title: title(tab))
                Spacer(minLength: 0)
                ToolbarIconButton("bubble.left", tr("tab.showAgent")) {
                    windows.showAgent(key, app: app)
                }
                ToolbarIconButton("sidebar.right", tr("tab.dock")) {
                    windows.dock(key, app: app)
                }
            }
            // Clear of the traffic lights, on the title bar's row.
            .padding(.leading, PanelSidebarMetrics.trafficLights - NookTheme.Spacing.lg)
            .frame(height: PanelSidebarMetrics.titleBand)
            panel(tab)
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.bottom, NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .top)
        .background(alignment: .top) {
            // The row with the traffic lights moves the window where no button lies on it.
            WindowTitleBarArea()
                .frame(height: PanelSidebarMetrics.titleBand)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
        }
        .background(NookTheme.canvas.ignoresSafeArea())
        // What the tab hands over lands in its own session's composer, whichever session the main window shows.
        .environment(\.sessionContextTarget, tab.directory.isEmpty && tab.runID == nil ? nil
            : SessionContextTarget(run: tab.runID, directory: tab.directory))
        .chatMediaStage(mediaStage)
        .nookToastHost()
        .tint(NookTheme.iris)
        .id("\(app.settings.accentHex)-\(app.settings.themeRevision)")
    }

    /// The session's name: its run's title, else its folder's.
    private func title(_ tab: DetachedSessionTab) -> String {
        if let id = tab.runID, let title = workspace.run(id)?.title, !title.isEmpty { return title }
        if !tab.directory.isEmpty { return (tab.directory as NSString).lastPathComponent }
        return tab.tool.title
    }

    private func panel(_ tab: DetachedSessionTab) -> some View {
        let report = reports.reports[tab.session] ?? SessionOutputsReport()
        var pullRequestTab = pullRequestTab
        pullRequestTab.request = tab.pullRequest
        return SessionToolPanel(
            directory: tab.directory, runID: tab.runID, tool: tab.tool, tabs: [tab.tool], pullRequest: tab.pullRequest,
            pullRequestTabs: [pullRequestTab], activePullRequest: pullRequestTab.id,
            outputs: report.outputs, outputSelection: $outputSelection, outputsFresh: false,
            subagents: report.subagents, commands: report.commands, subagentsFresh: false,
            turns: report.turns, diffSelection: $diffSelection,
            loadDiff: tab.runID.flatMap { id in
                workspace.run(id)?.isRemote == false ? { turn, files, options in
                    try await gitDiff(id, turn: turn, files: files, options: options)
                } : nil
            },
            closeHelp: tr("tab.close"),
            show: { _ in },
            selectPullRequest: { _ in },
            openPullRequest: { request in windows.update(key) { $0.pullRequest = request } },
            updatePullRequest: { request in windows.update(key) { $0.pullRequest = request } },
            showPullRequestList: { windows.update(key) { $0.pullRequest = nil } },
            closeTab: closeTab,
            close: { windows.close(key) },
            subThread: tab.subThread,
            openSubThreadHere: { id in
                app.viewModel.selectedAgentID = "run:" + id.uuidString
                app.openWindow(continuing: .agents)
                windows.close(key)
            },
            canAdd: false,
            file: Binding(get: { windows.tabs[key]?.file }, set: { file in windows.update(key) { $0.file = file } }))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One of several browser tabs closes by itself; the last one, or any other tab, closes the window.
    private func closeTab(_ tab: SessionTab) {
        if case .browser(let id) = tab, let current = windows.tabs[key],
           let browser = SessionBrowsers.shared.existing(BrowserSession(run: current.runID, directory: current.directory)),
           browser.pages.count > 1 {
            withAnimation(NookTheme.swap) { browser.close(id) }
            return
        }
        windows.close(key)
    }

    /// The real diff of these files in this turn, from the session's git snapshots, as the side panel reads it.
    private func gitDiff(_ id: UUID, turn: TurnDiff, files: [TurnDiff.File], options: DiffReadOptions) async throws -> String {
        guard let start = turn.start, let end = turn.end else { return "" }
        var parts: [String] = []
        for file in files {
            parts.append(try await workspace.turnDiff(id, path: file.path, start: start, end: end, options: options))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
