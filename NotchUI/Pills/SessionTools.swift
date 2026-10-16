import SwiftUI

/// What the right side of the Agents tab shows for a session: its conversation, a terminal in its folder (or worktree),
/// or Nook's browser, for instance on the dev server the agent started.
enum SessionTool: String {
    case conversation, terminal, browser
}

/// The terminal and the browser as two quiet icons in a session's header. The active one takes you back to the
/// conversation.
struct SessionToolSwitch: View {
    @ObservedObject var viewModel: NotchViewModel
    /// No folder, no terminal: a session without one only gets the browser.
    let hasFolder: Bool

    var body: some View {
        HStack(spacing: 2) {
            if hasFolder { icon(.terminal, symbol: "terminal", label: tr("agents.tool.terminal")) }
            icon(.browser, symbol: "safari", label: tr("agents.tool.browser"))
        }
    }

    private func icon(_ tool: SessionTool, symbol: String, label: String) -> some View {
        let active = viewModel.sessionTool == tool
        return Button {
            viewModel.sessionTool = active ? .conversation : tool
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? NookTheme.smoke : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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

    var body: some View {
        let tool = directory.isEmpty && viewModel.sessionTool == .terminal ? .conversation : viewModel.sessionTool
        if tool == .conversation {
            conversation(AnyView(SessionToolSwitch(viewModel: viewModel, hasFolder: !directory.isEmpty)))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                header(tool)
                ToolSurface {
                    switch tool {
                    case .terminal: SessionTerminalsView(directory: directory).id(directory)
                    default: BrowserView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            SessionToolSwitch(viewModel: viewModel, hasFolder: !directory.isEmpty)
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
