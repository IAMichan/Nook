import SwiftUI

/// What the side panel next to a session in the Agents tab shows: nothing (only the conversation), a terminal in its
/// folder (or worktree), Nook's browser, for instance on the dev server the agent started, or the folder's changes.
/// `picker` is the open side panel without a tool yet: it lists the tools to open.
enum SessionTool: String {
    case conversation, terminal, browser, changes, pullRequest, picker

    /// The tools the side panel can show, in the order its + menu and picker list them.
    static let panelTools: [SessionTool] = [.terminal, .browser, .changes]
    /// Tabs beside a session: the tools, and a pull request opened from a link in it (the side panel only, never in the
    /// + menu, and not kept across launches).
    static let sideTabs: [SessionTool] = panelTools + [.pullRequest]

    var symbol: String {
        switch self {
        case .conversation: return "bubble.left"
        case .terminal: return "terminal"
        case .browser: return "safari"
        case .changes: return "plus.forwardslash.minus"
        case .pullRequest: return "arrow.triangle.pull"
        case .picker: return "square.grid.2x2"
        }
    }

    /// Whether the tool works for a session in `directory`: without a folder there is only the browser.
    func available(in directory: String) -> Bool {
        if self == .pullRequest { return true }
        return directory.isEmpty ? self == .browser : Self.panelTools.contains(self)
    }

    /// The tab's name in the side panel.
    var title: String { tr("agents.tool.tab." + rawValue) }
    /// What the icon in the session's header does.
    var help: String { tr("agents.tool." + rawValue) }
}

/// The panels' quiet icons in a session's header: the terminal, the browser, and buttons that open (or close) the
/// bottom panel and the side panel. A tool's icon opens the side panel on it; on the tool the panel shows, it closes
/// the panel again. The bottom panel opens on what it showed last, the terminal by default; the side panel on what it
/// showed last, or on the list of tools when no tab is open. When the agent started a process or opened a page there
/// that you have not looked at yet, the icon carries a small dot.
struct SessionToolSwitch: View {
    @ObservedObject var viewModel: NotchViewModel
    /// The session's folder; empty means no terminal and no changes, only the browser.
    let directory: String
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.sideTool") private var lastTool = SessionTool.browser.rawValue
    @AppStorage("nook.agents.bottomTool") private var lastBottomTool = SessionTool.terminal.rawValue

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if !directory.isEmpty { icon(.terminal) }
            icon(.browser)
            ToolbarGroupDivider()
            bottomToggle
            panelToggle
        }
        .toolbarGroup()
    }

    private func icon(_ tool: SessionTool) -> some View {
        let active = viewModel.sessionTool == tool
        let fresh = !active && viewModel.bottomTool != tool && bridge.hasUnseen(directory, tool.rawValue)
        let help = fresh ? tool.help + " · " + tr("bridge.tool.unseen") : tool.help
        return Button {
            viewModel.sessionTool = active ? .conversation : tool
        } label: {
            SessionToolIcon(symbol: tool.symbol, active: active, fresh: fresh)
        }
        .buttonStyle(.plain)
        .animation(NookTheme.reveal, value: fresh)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Opens the bottom panel on the tool it showed last (the terminal at first), or closes it.
    private var bottomToggle: some View {
        let open = viewModel.bottomTool != .conversation
        let help = open ? tr("agents.tool.closeBottom") : tr("agents.tool.bottom")
        return Button {
            if open {
                viewModel.bottomTool = .conversation
            } else {
                let tabs = viewModel.bottomTabs.filter { $0.available(in: directory) }
                let last = SessionTool(rawValue: lastBottomTool) ?? .terminal
                if tabs.contains(last) {
                    viewModel.bottomTool = last
                } else if let first = tabs.first {
                    viewModel.bottomTool = first
                } else {
                    viewModel.bottomTool = SessionTool.terminal.available(in: directory) ? .terminal : .picker
                }
            }
        } label: {
            SessionToolIcon(symbol: "rectangle.bottomthird.inset.filled", active: open, fresh: false)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(open ? .isSelected : [])
    }

    /// Opens the side panel on the tool it showed last, or closes it.
    private var panelToggle: some View {
        let open = viewModel.sessionTool != .conversation
        let help = open ? tr("agents.tool.close") : tr("agents.tool.panel")
        return Button {
            if open {
                viewModel.sessionTool = .conversation
            } else {
                let tabs = viewModel.sessionTabs.filter { $0.available(in: directory) }
                let last = SessionTool(rawValue: lastTool) ?? .browser
                viewModel.sessionTool = tabs.contains(last) ? last : tabs.first ?? .picker
            }
        } label: {
            SessionToolIcon(symbol: "sidebar.right", active: open, fresh: false)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// One of the header's tool icons: highlighted while its tool is open, with a dot when there is something new.
private struct SessionToolIcon: View {
    let symbol: String
    let active: Bool
    let fresh: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 26, height: ToolbarGroup.itemHeight)
            .background(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius, style: .continuous).fill(active ? NookTheme.smoke : Color.clear))
            .overlay(alignment: .topTrailing) {
                if fresh {
                    Circle().fill(NookTheme.iris).frame(width: 5, height: 5).padding(NookTheme.Spacing.xs)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
    }
}

/// The header's buttons sit in a few quiet groups (outputs, the side panel's tools, the branch) instead of loose
/// icons: each group on one dark, softly outlined surface with its buttons inside.
enum ToolbarGroup {
    static let itemHeight: CGFloat = 22
    static let itemRadius: CGFloat = 6
    static let padding: CGFloat = 2
}

extension View {
    /// Plain icons with a fill only under the pointer: the group needs no box of its own.
    func toolbarGroup() -> some View {
        padding(ToolbarGroup.padding)
    }
}

/// The thin line between buttons inside one group.
struct ToolbarGroupDivider: View {
    var body: some View {
        Color.clear.frame(width: NookTheme.Spacing.xs, height: 12)
    }
}

/// Where a tool panel sits next to the conversation: what it shows and which tabs it has open in the view model.
private struct SessionPanelSlot {
    let tool: ReferenceWritableKeyPath<NotchViewModel, SessionTool>
    let tabs: ReferenceWritableKeyPath<NotchViewModel, [SessionTool]>
    let closeHelp: String

    @MainActor static let side = SessionPanelSlot(tool: \.sessionTool, tabs: \.sessionTabs, closeHelp: "agents.tool.close")
    @MainActor static let bottom = SessionPanelSlot(tool: \.bottomTool, tabs: \.bottomTabs, closeHelp: "agents.tool.closeBottom")
}

/// A session in the Agents tab together with the tools it works with. The conversation stays in view; a terminal, the
/// browser or the changes open in a side panel on its right or a bottom panel under it, each in a tab you open with +
/// and close with its cross. A tool is open in one of the two at a time. With no tab open a panel lists the tools.
/// Drag the line beside (or above) a panel to make it wider (or taller).
struct SessionWorkbench<Conversation: View>: View {
    @ObservedObject var viewModel: NotchViewModel
    let directory: String
    /// A session Nook runs: its changes open in its own review, with comments for the agent.
    var runID: UUID? = nil
    @ViewBuilder var conversation: (AnyView) -> Conversation
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.sideTool") private var lastTool = SessionTool.browser.rawValue
    @AppStorage("nook.agents.bottomTool") private var lastBottomTool = SessionTool.terminal.rawValue
    @AppStorage("nook.agents.toolWidth") private var toolWidth = PanelLayout.tool
    @AppStorage("nook.agents.bottomHeight") private var bottomHeight = BottomPanelLayout.standard
    @State private var totalWidth: Double = 0
    @State private var totalHeight: Double = 0
    @State private var dragStart: Double?

    /// What a panel shows: nothing (closed), the list of tools, or one this session can use.
    private func shown(_ slot: SessionPanelSlot) -> SessionTool {
        let selected = viewModel[keyPath: slot.tool]
        if selected == .conversation { return .conversation }
        return selected.available(in: directory) ? selected : .picker
    }

    /// The open tabs this session can show in a panel.
    private func tabs(_ slot: SessionPanelSlot) -> [SessionTool] {
        viewModel[keyPath: slot.tabs].filter { $0.available(in: directory) }
    }

    var body: some View {
        let side = shown(.side)
        let bottom = shown(.bottom)
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                conversation(AnyView(SessionToolSwitch(viewModel: viewModel, directory: directory)))
                    // A pull request link in the conversation opens in the side panel.
                    .environment(\.pullRequestLinksBeside, true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if bottom != .conversation {
                    VStack(spacing: 0) {
                        BottomSplitHandle(onDrag: dragBottom, onEnd: { dragStart = nil },
                                          onReset: { bottomHeight = BottomPanelLayout.standard })
                        panel(.bottom, tool: bottom)
                    }
                    .frame(height: CGFloat(BottomPanelLayout.height(bottomHeight, available: totalHeight)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { totalHeight = $0 }
            if side != .conversation {
                panel(.side, tool: side)
                    .padding(.leading, NookTheme.Spacing.sm)
                    .resizablePanel(width: $toolWidth, defaultWidth: PanelLayout.tool, minimum: PanelLayout.minimumPanel,
                                    available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                                    edge: .leading, divider: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .animation(NookTheme.reveal, value: side == .conversation)
        .animation(NookTheme.reveal, value: bottom == .conversation)
        .onChange(of: side) { _, next in
            if SessionTool.panelTools.contains(next) { lastTool = next.rawValue }
        }
        .onChange(of: bottom) { _, next in
            if SessionTool.panelTools.contains(next) { lastBottomTool = next.rawValue }
        }
    }

    /// Dragging the line above the bottom panel up makes it taller.
    private func dragBottom(_ offset: Double) {
        let start = dragStart ?? BottomPanelLayout.height(bottomHeight, available: totalHeight)
        dragStart = start
        bottomHeight = BottomPanelLayout.height(start - offset, available: totalHeight)
    }

    private func panel(_ slot: SessionPanelSlot, tool: SessionTool) -> some View {
        SessionToolPanel(directory: directory, runID: runID, tool: tool, tabs: tabs(slot), pullRequest: viewModel.sidePullRequest,
                         closeHelp: tr(slot.closeHelp),
                         show: { item in withAnimation(NookTheme.swap) { viewModel[keyPath: slot.tool] = item } },
                         closeTab: { closeTab($0, in: slot) },
                         close: { viewModel[keyPath: slot.tool] = .conversation })
    }

    /// Closes a tab; when it was the one in view, the tab next to it takes its place, or the list of tools.
    private func closeTab(_ item: SessionTool, in slot: SessionPanelSlot) {
        let visible = tabs(slot)
        guard let index = visible.firstIndex(of: item) else { return }
        let rest = visible.filter { $0 != item }
        withAnimation(NookTheme.swap) {
            viewModel[keyPath: slot.tabs].removeAll { $0 == item }
            if item == .pullRequest { viewModel.sidePullRequest = nil }
            if viewModel[keyPath: slot.tool] == item {
                viewModel[keyPath: slot.tool] = rest.isEmpty ? .picker : rest[min(index, rest.count - 1)]
            }
        }
    }
}

/// How tall the bottom panel under a conversation is: what you dragged it to, leaving the conversation room.
enum BottomPanelLayout {
    static let standard: Double = 240
    static let minimum: Double = 120
    /// Room the conversation (its header and composer) keeps above the bottom panel.
    static let conversation: Double = 200

    static func height(_ wanted: Double, available: Double) -> Double {
        let most = max(minimum, available - conversation)
        return min(max(wanted, minimum), most)
    }
}

/// The line above the bottom panel: drag it to make the panel taller or shorter, double-click for its usual height.
private struct BottomSplitHandle: View {
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        ZStack {
            NookDivider()
            Capsule()
                .fill(hovering || dragging ? NookTheme.textSecondary : NookTheme.line2)
                .frame(width: 36, height: 4)
                .opacity(hovering || dragging ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else if !dragging { NSCursor.pop() }
        }
        .gesture(
            // Global coordinates: the line itself moves while you drag it.
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dragging = true
                    onDrag(Double(value.translation.height))
                }
                .onEnded { _ in
                    dragging = false
                    if !hovering { NSCursor.pop() }
                    onEnd()
                }
        )
        .onTapGesture(count: 2) { onReset() }
        .help(tr("panel.resize"))
        .accessibilityLabel(tr("panel.resize"))
    }
}

/// A tool panel beside or under a session: its open tools as tabs, + to open another, the button that closes it, and
/// the tool in view (or the list of tools while none is open). It sits flat on the notch, not as a card.
private struct SessionToolPanel: View {
    let directory: String
    let runID: UUID?
    let tool: SessionTool
    let tabs: [SessionTool]
    let pullRequest: PullRequestOpenRequest?
    let closeHelp: String
    let show: (SessionTool) -> Void
    let closeTab: (SessionTool) -> Void
    let close: () -> Void
    @ObservedObject private var bridge = WorkspaceBridge.shared

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header
            if tool == .browser, !directory.isEmpty { DevServerStrip(directory: directory) }
            Group {
                switch tool {
                case .picker:
                    SessionToolPicker(directory: directory) { show($0) }
                case .terminal: SessionTerminalsView(directory: directory).id(directory)
                case .changes:
                    if let runID {
                        ChangesSheet(runID: runID, initialFile: nil, onClose: close, stacked: true).id(runID)
                    } else {
                        FolderChangesSheet(directory: directory, stacked: true).id(directory)
                    }
                case .pullRequest:
                    if let pullRequest {
                        PullRequestDetailView(accountID: pullRequest.account, item: pullRequest.item)
                            .id(pullRequest.account + " " + pullRequest.item.id)
                    } else {
                        SessionToolPicker(directory: directory) { show($0) }
                    }
                default: BrowserView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // What the agent opened here is in view now, also when it opens more while you look.
        .onAppear { bridge.markSeen(directory, tool.rawValue) }
        .onChange(of: tool) { _, next in bridge.markSeen(directory, next.rawValue) }
        .onChange(of: bridge.unseen) { _, _ in bridge.markSeen(directory, tool.rawValue) }
    }

    /// The open tabs, + to open another, and the button that closes the panel.
    private var header: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if !tabs.isEmpty {
                NookTabBar(items: tabs.map { item in
                    NookTabBar<SessionTool>.Item(value: item, title: item.title, symbol: item.symbol,
                                                 fresh: item != tool && bridge.hasUnseen(directory, item.rawValue), help: item.help)
                }, selected: tool, onSelect: show, onClose: closeTab)
            }
            addMenu
            Spacer(minLength: 8)
            if tool == .terminal {
                Text(AgentPathFormat.tilde(directory))
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SessionTerminalActions(directory: directory).id(directory)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(NookTheme.font(10.5, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(closeHelp)
            .accessibilityLabel(closeHelp)
        }
        .frame(height: 34)
    }

    /// + : the tools to open, each in its own tab (or the tab it already has).
    private var addMenu: some View {
        Menu {
            ForEach(SessionTool.panelTools, id: \.self) { item in
                Button { show(item) } label: { Label(item.title, systemImage: item.symbol) }
                    .disabled(!item.available(in: directory))
            }
        } label: {
            Image(systemName: "plus")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.tool.add"))
        .accessibilityLabel(tr("agents.tool.add"))
    }
}

/// An open panel before any tab: the tools, one row each, to open in a tab. A tool the session cannot use
/// (a terminal or changes without a folder) is shown dimmed.
private struct SessionToolPicker: View {
    let directory: String
    let onOpen: (SessionTool) -> Void

    var body: some View {
        VStack(spacing: NookTheme.Spacing.lg) {
            Text(tr("agents.tool.pick"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
            VStack(spacing: NookTheme.Spacing.xxs) {
                ForEach(SessionTool.panelTools, id: \.self) { tool in
                    SessionToolPickerRow(tool: tool, enabled: tool.available(in: directory)) { onOpen(tool) }
                }
            }
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, NookTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SessionToolPickerRow: View {
    let tool: SessionTool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(NookTheme.font(12, .medium))
                    .frame(width: 16)
                Text(tool.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(enabled ? NookTheme.paper : NookTheme.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(hovering && enabled ? NookTheme.smoke : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? tool.help : tr("agents.tool.needsFolder"))
        .onHover { hovering = $0 }
    }
}

/// The rounded, slightly lifted surface a terminal, the browser or the worktrees sit on inside the notch.
struct ToolSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.field))
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
    }
}

/// A footer page that is one of the tools on its own: every terminal, the browser, or every worktree.
struct AgentsToolPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            PanelListHeader(title)
            ToolSurface(content: content)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The local servers this session's folder runs, as small buttons
/// above the browser: one tap opens it. Checked every few seconds while the browser is open.
struct DevServerStrip: View {
    let directory: String
    @State private var servers: [DevServer] = []
    @ObservedObject private var browser = BrowserStore.shared

    var body: some View {
        // A VStack, not a Group: it exists while still empty, so the scan below starts.
        VStack(alignment: .leading, spacing: 0) {
            if !servers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(NookTheme.font(10, .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .help(tr("agents.servers.help"))
                        ForEach(servers) { server in
                            // `address` is published, unlike the web view's own URL.
                            let open = URL(string: browser.address)?.port == server.port
                            Button {
                                browser.go(server.url.absoluteString)
                            } label: {
                                Text("\(server.command) — :\(server.port)")
                                    .font(NookTheme.TextStyle.label)
                                    .foregroundStyle(open ? NookTheme.paper : NookTheme.textSecondary)
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .background(Capsule().fill(open ? NookTheme.smoke : NookTheme.field))
                            }
                            .buttonStyle(.plain)
                            .help(server.url.absoluteString)
                        }
                    }
                }
            }
        }
        .task(id: directory) {
            let folder = WorkspacePathPolicy.normalize(directory)
            // Each scan starts `lsof` twice (100–500 ms of work). Every 3 seconds right after something changed, so a
            // server that just started shows up at once; up to every 15 seconds while the list stays the same.
            var wait: UInt64 = 3
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { () async -> [DevServer] in
                    // Only listeners that serve a page: not the folder's database or debugger.
                    var servers = await DevServerProbe.pages(DevServerScanner.scan(folder: folder))
                    // Pages the project names (nook.json previewUrl) on localhost, when they are not already found.
                    for script in ProjectScripts.load(folder: folder) {
                        guard let url = script.previewURL, let port = url.port, BridgeURLPolicy.isLoopback(url.host ?? ""),
                              !servers.contains(where: { $0.port == port }) else { continue }
                        servers.append(DevServer(pid: 0, command: script.name, port: port))
                    }
                    return servers.sorted { $0.port < $1.port }
                }.value
                if found != servers {
                    withAnimation(NookTheme.reveal) { servers = found }
                    wait = 3
                } else {
                    wait = min(wait + 3, 15)
                }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }
}
