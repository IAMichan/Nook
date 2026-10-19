import SwiftUI

/// What the side panel next to a session in the Agents tab shows: nothing (only the conversation), a terminal in its
/// folder (or worktree), Nook's browser, for instance on the dev server the agent started, or the folder's changes.
/// `picker` is the open side panel without a tool yet: it lists the tools to open.
enum SessionTool: String {
    case conversation, terminal, browser, changes, picker

    /// The tools the side panel can show, in the order its + menu and picker list them.
    static let panelTools: [SessionTool] = [.terminal, .browser, .changes]

    var symbol: String {
        switch self {
        case .conversation: return "bubble.left"
        case .terminal: return "terminal"
        case .browser: return "safari"
        case .changes: return "plus.forwardslash.minus"
        case .picker: return "square.grid.2x2"
        }
    }

    /// Whether the tool works for a session in `directory`: without a folder there is only the browser.
    func available(in directory: String) -> Bool {
        directory.isEmpty ? self == .browser : Self.panelTools.contains(self)
    }

    /// The tab's name in the side panel.
    var title: String { tr("agents.tool.tab." + rawValue) }
    /// What the icon in the session's header does.
    var help: String { tr("agents.tool." + rawValue) }
}

/// The side panel's quiet icons in a session's header: the terminal, the browser and a button that opens (or closes)
/// the side panel on what it showed last, or on the list of tools when no tab is open. A tool's icon opens the panel
/// on it; on the tool the panel shows, it closes the panel again. When the agent started a process or opened a page there that you have not looked at yet, the icon
/// carries a small dot.
struct SessionToolSwitch: View {
    @ObservedObject var viewModel: NotchViewModel
    /// The session's folder; empty means no terminal and no changes, only the browser.
    let directory: String
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.sideTool") private var lastTool = SessionTool.browser.rawValue

    var body: some View {
        HStack(spacing: 2) {
            if !directory.isEmpty { icon(.terminal) }
            icon(.browser)
            ToolbarGroupDivider()
            panelToggle
        }
        .toolbarGroup()
    }

    private func icon(_ tool: SessionTool) -> some View {
        let active = viewModel.sessionTool == tool
        let fresh = !active && bridge.hasUnseen(directory, tool.rawValue)
        let help = fresh ? tool.help + " · " + tr("bridge.tool.unseen") : tool.help
        return Button {
            viewModel.sessionTool = active ? .conversation : tool
        } label: {
            SessionToolIcon(symbol: tool.symbol, active: active, fresh: fresh)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: fresh)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
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
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 26, height: ToolbarGroup.itemHeight)
            .background(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius, style: .continuous).fill(active ? NookTheme.smoke : Color.clear))
            .overlay(alignment: .topTrailing) {
                if fresh {
                    Circle().fill(NookTheme.iris).frame(width: 5, height: 5).padding(4)
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
    func toolbarGroup() -> some View {
        padding(ToolbarGroup.padding)
            .background(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius + ToolbarGroup.padding, style: .continuous).fill(NookTheme.field))
            .overlay(RoundedRectangle(cornerRadius: ToolbarGroup.itemRadius + ToolbarGroup.padding, style: .continuous)
                .stroke(NookTheme.line2.opacity(0.7), lineWidth: 0.5))
    }
}

/// The thin line between buttons inside one group.
struct ToolbarGroupDivider: View {
    var body: some View {
        Rectangle().fill(NookTheme.line2).frame(width: 1, height: 12).padding(.horizontal, 2)
    }
}

/// A session in the Agents tab together with the tools it works with. The conversation stays in view; a terminal, the
/// browser or the changes open in a side panel on its right, each in a tab you open with + and close with its cross.
/// With no tab open the panel lists the tools. Drag the line beside the panel to make it wider or narrower.
struct SessionWorkbench<Conversation: View>: View {
    @ObservedObject var viewModel: NotchViewModel
    let directory: String
    /// A session Nook runs: its changes open in its own review, with comments for the agent.
    var runID: UUID? = nil
    @ViewBuilder var conversation: (AnyView) -> Conversation
    @ObservedObject private var bridge = WorkspaceBridge.shared
    @AppStorage("nook.agents.sideTool") private var lastTool = SessionTool.browser.rawValue
    @AppStorage("nook.agents.toolWidth") private var toolWidth = PanelLayout.tool
    @State private var totalWidth: Double = 0

    /// The open tabs this session can show.
    private var tabs: [SessionTool] { viewModel.sessionTabs.filter { $0.available(in: directory) } }

    var body: some View {
        let selected = viewModel.sessionTool
        let tool = selected == .picker || selected.available(in: directory) ? selected : .conversation
        HStack(alignment: .top, spacing: 0) {
            conversation(AnyView(SessionToolSwitch(viewModel: viewModel, directory: directory)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if tool != .conversation {
                sidePanel(tool)
                    .padding(.leading, 6)
                    .resizablePanel(width: $toolWidth, defaultWidth: PanelLayout.tool, minimum: PanelLayout.minimumPanel,
                                    available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                                    edge: .leading, divider: true)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .animation(.easeInOut(duration: 0.2), value: tool == .conversation)
        .onChange(of: tool) { _, next in
            if SessionTool.panelTools.contains(next) { lastTool = next.rawValue }
        }
    }

    /// The panel sits flat on the notch, set apart from the conversation by the line you drag, not as a card.
    private func sidePanel(_ tool: SessionTool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(tool)
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

    private func close() { viewModel.sessionTool = .conversation }

    /// Shows `item`, in a new tab when it has none yet.
    private func show(_ item: SessionTool) {
        withAnimation(NookTheme.swap) { viewModel.sessionTool = item }
    }

    /// Closes a tab; when it was the one in view, the tab next to it takes its place, or the list of tools.
    private func closeTab(_ item: SessionTool) {
        let visible = tabs
        guard let index = visible.firstIndex(of: item) else { return }
        let rest = visible.filter { $0 != item }
        withAnimation(NookTheme.swap) {
            viewModel.sessionTabs.removeAll { $0 == item }
            if viewModel.sessionTool == item { viewModel.sessionTool = rest.isEmpty ? .picker : rest[min(index, rest.count - 1)] }
        }
    }

    /// The open tabs, + to open another, and the button that closes the panel.
    private func header(_ tool: SessionTool) -> some View {
        HStack(spacing: 4) {
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
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("agents.tool.close"))
            .accessibilityLabel(tr("agents.tool.close"))
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
                .font(.system(size: 11, weight: .semibold))
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

/// The open side panel before any tab: the tools, one row each, to open in a tab. A tool the session cannot use
/// (a terminal or changes without a folder) is shown dimmed.
private struct SessionToolPicker: View {
    let directory: String
    let onOpen: (SessionTool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(tr("agents.tool.pick"))
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.paper)
            VStack(spacing: 2) {
                ForEach(SessionTool.panelTools, id: \.self) { tool in
                    SessionToolPickerRow(tool: tool, enabled: tool.available(in: directory)) { onOpen(tool) }
                }
            }
            .frame(maxWidth: 260)
        }
        .padding(.horizontal, 16)
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
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(tool.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(NookTheme.font(13))
            .foregroundStyle(enabled ? NookTheme.paper : NookTheme.textTertiary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering && enabled ? NookTheme.smoke : Color.clear))
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.field))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NookTheme.line2.opacity(0.6), lineWidth: 1))
    }
}

/// A footer page that is one of the tools on its own: every terminal, the browser, or every worktree.
struct AgentsToolPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
                .frame(height: 30)
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
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .help(tr("agents.servers.help"))
                        ForEach(servers) { server in
                            // `address` is published, unlike the web view's own URL.
                            let open = URL(string: browser.address)?.port == server.port
                            Button {
                                browser.go(server.url.absoluteString)
                            } label: {
                                Text("\(server.command) — :\(server.port)")
                                    .font(NookTheme.font(11.5, .medium))
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
                let found = await Task.detached(priority: .utility) { () -> [DevServer] in
                    var servers = DevServerScanner.scan(folder: folder)
                    // Pages the project names (nook.json previewUrl) on localhost, when they are not already found.
                    for script in ProjectScripts.load(folder: folder) {
                        guard let url = script.previewURL, let port = url.port, BridgeURLPolicy.isLoopback(url.host ?? ""),
                              !servers.contains(where: { $0.port == port }) else { continue }
                        servers.append(DevServer(pid: 0, command: script.name, port: port))
                    }
                    return servers.sorted { $0.port < $1.port }
                }.value
                if found != servers {
                    withAnimation(.easeOut(duration: 0.15)) { servers = found }
                    wait = 3
                } else {
                    wait = min(wait + 3, 15)
                }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }
}
