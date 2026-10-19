import SwiftUI

/// What the right side of the Agents tab shows for a session: its conversation, a terminal in its folder (or worktree),
/// or Nook's browser, for instance on the dev server the agent started.
enum SessionTool: String {
    case conversation, terminal, browser
}

/// The terminal and the browser as two quiet icons in a session's header. The active one takes you back to the
/// conversation. When the agent started a process or opened a page there that you have not looked at yet, the icon
/// carries a small dot.
struct SessionToolSwitch: View {
    @ObservedObject var viewModel: NotchViewModel
    /// The session's folder; empty means no terminal, only the browser.
    let directory: String
    @ObservedObject private var bridge = WorkspaceBridge.shared

    var body: some View {
        HStack(spacing: 2) {
            if !directory.isEmpty { icon(.terminal, symbol: "terminal", label: tr("agents.tool.terminal")) }
            icon(.browser, symbol: "safari", label: tr("agents.tool.browser"))
        }
    }

    private func icon(_ tool: SessionTool, symbol: String, label: String) -> some View {
        let active = viewModel.sessionTool == tool
        let fresh = !active && bridge.hasUnseen(directory, tool.rawValue)
        let help = fresh ? label + " · " + tr("bridge.tool.unseen") : label
        return Button {
            viewModel.sessionTool = active ? .conversation : tool
        } label: {
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
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: fresh)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A session in the Agents tab together with the tools it works with. On its conversation the header carries the
/// terminal and browser icons; with one of them open, the tool fills the space and the header leads back.
struct SessionWorkbench<Conversation: View>: View {
    @ObservedObject var viewModel: NotchViewModel
    let title: String
    let directory: String
    @ViewBuilder var conversation: (AnyView) -> Conversation
    @ObservedObject private var bridge = WorkspaceBridge.shared

    var body: some View {
        let tool = directory.isEmpty && viewModel.sessionTool == .terminal ? .conversation : viewModel.sessionTool
        if tool == .conversation {
            conversation(AnyView(SessionToolSwitch(viewModel: viewModel, directory: directory)))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header(tool)
                if tool == .browser, !directory.isEmpty { DevServerStrip(directory: directory) }
                ToolSurface {
                    switch tool {
                    case .terminal: SessionTerminalsView(directory: directory).id(directory)
                    default: BrowserView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // What the agent opened here is in view now, also when it opens more while you look.
            .onAppear { bridge.markSeen(directory, tool.rawValue) }
            .onChange(of: bridge.unseen) { _, _ in bridge.markSeen(directory, tool.rawValue) }
        }
    }

    /// "‹ Session title · ~/folder" with the same two icons on the right.
    private func header(_ tool: SessionTool) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.sessionTool = .conversation
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(title).font(NookTheme.font(13.5, .medium)).lineLimit(1)
                }
                .foregroundStyle(NookTheme.paper)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("agents.tool.back"))
            if tool == .terminal {
                Text(AgentPathFormat.tilde(directory))
                    .font(NookTheme.mono(11.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SessionToolSwitch(viewModel: viewModel, directory: directory)
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
                if found != servers { withAnimation(.easeOut(duration: 0.15)) { servers = found } }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
