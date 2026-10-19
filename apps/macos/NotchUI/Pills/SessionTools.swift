import SwiftUI

/// What the side panel next to a session in the Agents tab shows: nothing (only the conversation), a terminal in its
/// folder (or worktree), Nook's browser, for instance on the dev server the agent started, or the folder's changes.
enum SessionTool: String {
    case conversation, terminal, browser, changes

    /// The tools the side panel can show, in the order of its tabs.
    static let panelTools: [SessionTool] = [.terminal, .browser, .changes]

    var symbol: String {
        switch self {
        case .conversation: return "bubble.left"
        case .terminal: return "terminal"
        case .browser: return "safari"
        case .changes: return "plus.forwardslash.minus"
        }
    }

    /// The tab's name in the side panel.
    var title: String { tr("agents.tool.tab." + rawValue) }
    /// What the icon in the session's header does.
    var help: String { tr("agents.tool." + rawValue) }
}

/// The side panel's quiet icons in a session's header: the terminal, the browser and a button that opens (or closes)
/// the side panel on what it showed last. A tool's icon opens the panel on it; on the tool the panel shows, it closes
/// the panel again. When the agent started a process or opened a page there that you have not looked at yet, the icon
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
            panelToggle
        }
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
                let last = SessionTool(rawValue: lastTool) ?? .browser
                viewModel.sessionTool = directory.isEmpty && last != .browser ? .browser : last
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? NookTheme.smoke : Color.clear))
            .overlay(alignment: .topTrailing) {
                if fresh {
                    Circle().fill(NookTheme.iris).frame(width: 6, height: 6).padding(5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
    }
}

/// A session in the Agents tab together with the tools it works with. The conversation stays in view; a terminal, the
/// browser or the changes open in a side panel on its right, with tabs on top to switch between them. Drag the line
/// beside the panel to make it wider or narrower.
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

    private var tools: [SessionTool] { directory.isEmpty ? [.browser] : SessionTool.panelTools }

    var body: some View {
        let tool = tools.contains(viewModel.sessionTool) ? viewModel.sessionTool : .conversation
        HStack(alignment: .top, spacing: 0) {
            conversation(AnyView(SessionToolSwitch(viewModel: viewModel, directory: directory)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if tool != .conversation {
                sidePanel(tool)
                    .padding(.leading, 6)
                    .resizablePanel(width: $toolWidth, defaultWidth: PanelLayout.tool, minimum: PanelLayout.minimumPanel,
                                    available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle,
                                    edge: .leading)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .animation(.easeInOut(duration: 0.2), value: tool == .conversation)
        .onChange(of: tool) { _, next in
            if next != .conversation { lastTool = next.rawValue }
        }
    }

    private func sidePanel(_ tool: SessionTool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(tool)
            if tool == .browser, !directory.isEmpty { DevServerStrip(directory: directory) }
            ToolSurface {
                switch tool {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // What the agent opened here is in view now, also when it opens more while you look.
        .onAppear { bridge.markSeen(directory, tool.rawValue) }
        .onChange(of: tool) { _, next in bridge.markSeen(directory, next.rawValue) }
        .onChange(of: bridge.unseen) { _, _ in bridge.markSeen(directory, tool.rawValue) }
    }

    private func close() { viewModel.sessionTool = .conversation }

    /// The tabs to choose what the panel shows, and the button that closes it.
    private func header(_ tool: SessionTool) -> some View {
        HStack(spacing: 4) {
            NookTabBar(items: tools.map { item in
                NookTabBar<SessionTool>.Item(value: item, title: item.title, symbol: item.symbol,
                                             fresh: item != tool && bridge.hasUnseen(directory, item.rawValue), help: item.help)
            }, selected: tool) { item in
                withAnimation(NookTheme.swap) { viewModel.sessionTool = item }
            }
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
        .frame(height: 30)
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
