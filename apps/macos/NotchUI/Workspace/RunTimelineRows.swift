import SwiftUI

// The rows of a session's timeline (messages, thinking, tool calls, approvals), shared by the session views.

struct EventRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void
    let openFile: (String) -> Void
    let decide: (WorkspaceManager.Decision) -> Void
    /// Shows a file the agent read or wrote in the side panel; nil where there is no side panel.
    var showFile: ((String) -> Void)? = nil
    /// The folder relative paths resolve in, and the file the side panel shows now.
    var directory: String? = nil
    var shownFile: String? = nil

    var body: some View {
        switch event.kind {
        case .user:
            ConversationMessage(fromUser: true, text: event.text)
                .padding(.top, 6)

        case .assistant:
            ConversationMessage(fromUser: false, text: event.text)
                .padding(.horizontal, 2)

        case .thinking:
            // The agent's reasoning in the chat itself: muted, live while it is written, the first
            // lines at once and the rest a click away.
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain").font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.iris)
                        Text(event.state == .running ? tr("ws.event.thinkingLive") : tr("ws.event.thinking"))
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(WS.tertiary)
                        if event.text.count > 280 || event.text.split(separator: "\n").count > 4 {
                            Image(systemName: "chevron.right")
                                .font(NookTheme.font(8.5, .bold))
                                .foregroundStyle(WS.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        Spacer(minLength: 0)
                    }
                    Text(event.text)
                        .font(NookTheme.font(12))
                        .foregroundStyle(WS.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(expanded || event.state == .running ? nil : 4)
                        .opacity(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(NookTheme.iris.opacity(0.35)).frame(width: 2) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        case .tool:
            if let showFile, let file = ToolRow.file(event, in: directory) {
                ToolRow(event: event, expanded: false, toggle: { showFile(file) }, file: file, reveals: file == shownFile)
            } else {
                ToolRow(event: event, expanded: expanded, toggle: toggle)
            }

        case .fileChange:
            Button { openFile(event.detail ?? event.text) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.badge.ellipsis")
                        .foregroundStyle(NookTheme.iris)
                    Text(event.text).font(NookTheme.mono(11.5)).foregroundStyle(WS.text)
                    Text(tr("ws.change." + (event.tool ?? "modified"))).font(NookTheme.TextStyle.detail).foregroundStyle(WS.tertiary)
                    Image(systemName: "arrow.up.right.square").font(NookTheme.font(10)).foregroundStyle(WS.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help(tr("ws.change.openDiff"))

        case .approval:
            ApprovalRow(event: event, expanded: expanded, toggle: toggle, decide: decide)

        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(NookTheme.coral)
                Text(event.text)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.coralSoft)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.coral.opacity(0.08)))

        case .system where event.tool == "handoff":
            // What the new agent was given: a summary you can read, not a hidden prompt.
            DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { _ in toggle() })) {
                Text(event.detail ?? "")
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(WS.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap").font(NookTheme.font(10))
                    Text(event.text).font(NookTheme.font(11.5)).lineLimit(2)
                    Spacer(minLength: 0)
                    Text(WSFormat.time(event.date)).font(NookTheme.font(10.5))
                }
                .foregroundStyle(WS.tertiary)
            }

        case .system:
            HStack(spacing: 6) {
                Image(systemName: event.tool == "launch" ? "terminal" : "info.circle").font(NookTheme.font(10))
                Text(event.text)
                    .font(event.tool == "launch" ? NookTheme.mono(11) : NookTheme.font(11.5))
                    .lineLimit(event.tool == "launch" ? 1 : 3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(WSFormat.time(event.date)).font(NookTheme.font(10.5))
            }
            .foregroundStyle(WS.tertiary)

        case .result:
            HStack(spacing: 8) {
                Rectangle().fill(WS.border).frame(height: 1)
                Image(systemName: event.state == .failed ? "xmark.circle" : "checkmark.circle")
                    .foregroundStyle(event.state == .failed ? NookTheme.coral : NookTheme.mint)
                Text(event.text.isEmpty ? tr("ws.event.turnDone") : tr("ws.event.turnDoneWith", event.text))
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(WS.tertiary)
                    .fixedSize()
                Rectangle().fill(WS.border).frame(height: 1)
            }
            .padding(.vertical, 4)
        }
    }
}

/// A tool call: single-line summary, expandable to inspect input and output. A call that read or wrote a file instead
/// opens that file in the side panel (`file`), the way a step in an agent's transcript does.
struct ToolRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void
    var file: String? = nil
    /// The side panel shows `file` now.
    var reveals = false

    /// The file a read or an edit was about, as an absolute path; nil for other tools, a folder, or a remote session.
    static func file(_ event: RunEvent, in directory: String?) -> String? {
        guard let directory, [.read, .edit].contains(ToolCategory.of(tool: event.tool ?? "")),
              let raw = ToolSummary.path(AgentActivity.input(event.detail) ?? [:]) else { return nil }
        let path = SessionOutputs.resolve(raw, in: directory)
        var folder: ObjCBool = false
        guard !path.isEmpty, !(FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue) else { return nil }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    stateIcon
                        .frame(width: 14)
                    Image(systemName: Self.symbol(event.tool ?? ""))
                        .font(NookTheme.font(10.5))
                        .foregroundStyle(WS.tertiary)
                    Text(event.text)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(WS.text.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if event.state != .failed, let lines = EditLines.of(event) { EditLinesLabel(lines: lines) }
                    // A test run, build or linter says how it went.
                    if let check = Verification.check(event) { VerificationChips(checks: [check]) }
                    Spacer(minLength: 0)
                    Image(systemName: file != nil ? "sidebar.right" : expanded ? "chevron.down" : "chevron.right")
                        .font(NookTheme.font(9, .semibold))
                        .foregroundStyle(reveals ? WS.text : WS.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(file.map { tr("ws.file.show") + " · " + AgentPathFormat.tilde($0) } ?? "")
            .accessibilityLabel(event.text)
            .accessibilityHint(file != nil ? tr("ws.file.show") : tr("ws.tool.expandHint"))
            .accessibilityAddTraits(reveals ? .isSelected : [])

            // An MCP app is there to be used: shown whether or not the call is open.
            if let app = McpUI.resource(in: event.output) {
                McpAppBlock(resource: app, event: event).padding(.leading, 22)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    // A task list (TodoWrite, update_plan) reads as the list, not as its JSON.
                    if let steps = SessionOutputs.taskList(tool: event.tool ?? "", input: AgentActivity.input(event.detail) ?? [:]),
                       !steps.isEmpty {
                        TaskListRows(steps: steps)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.field))
                    } else if let detail = event.detail, !detail.isEmpty, detail != "{}" {
                        CodeBlock(title: tr("ws.tool.input"), text: detail)
                    }
                    if let output = event.output.map(McpUI.stripped), !output.isEmpty {
                        CodeBlock(title: tr("ws.tool.output"), text: output, failed: event.state == .failed)
                    } else if event.state == .running {
                        Text(tr("ws.tool.running")).font(NookTheme.font(11.5)).foregroundStyle(WS.tertiary)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch event.state {
        case .running: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "xmark").font(NookTheme.font(9, .bold)).foregroundStyle(NookTheme.coral)
        default: Image(systemName: "checkmark").font(NookTheme.font(9, .bold)).foregroundStyle(NookTheme.mint.opacity(0.8))
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Bash", "shell", "BashOutput", "KillShell": return "terminal"
        case "Read", "NotebookRead": return "doc.text"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch", "web_search": return "globe"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        default: return tool.hasPrefix("mcp") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}

struct CodeBlock: View {
    let title: String
    let text: String
    var failed = false
    /// The text's own height: the block is as tall as it, up to `maxHeight`, and scrolls beyond that.
    @State private var height: CGFloat = 0
    private let maxHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(NookTheme.font(10.5, .semibold)).foregroundStyle(WS.tertiary)
                Spacer()
                Button {
                    Pasteboard.copy(text)
                } label: {
                    Image(systemName: "doc.on.doc").font(NookTheme.font(10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WS.tertiary)
                .help(tr("button.copy"))
            }
            // Both ways, at a fixed height: a long output (a whole file) scrolls inside the block instead of spilling
            // over the rows around it.
            ScrollView([.horizontal, .vertical], showsIndicators: height > maxHeight) {
                Text(text)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(failed ? NookTheme.coralSoft : NookTheme.textStrong)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(max(height, 14), maxHeight))
            .clipped()
        }
        .padding(10)
        .cardBackground(WS.code, stroke: WS.border, radius: NookTheme.Radius.control)
    }
}

/// An approval request in the timeline. If still pending, you can respond directly here.
struct ApprovalRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void
    let decide: (WorkspaceManager.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(tr("ws.approval.asks", McpToolName(event.tool ?? "")?.toolLabel ?? event.tool ?? "tool"))
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(WS.text)
                Text(event.text).font(NookTheme.mono(11.5)).foregroundStyle(WS.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(stateLabel).font(NookTheme.font(11.5, .semibold)).foregroundStyle(color)
            }
            if expanded, let detail = event.detail {
                CodeBlock(title: tr("ws.tool.input"), text: detail)
            }
        }
        .padding(10)
        // Calm: the state label carries the color, the row itself stays neutral.
        .cardBackground(Color.white.opacity(0.03), stroke: Color.white.opacity(0.08), radius: NookTheme.Radius.control)
        .onTapGesture { toggle() }
    }

    private var color: Color {
        switch event.state {
        case .pending: return NookTheme.amber
        case .allowed: return NookTheme.mint
        case .denied: return NookTheme.coral
        default: return WS.tertiary
        }
    }

    private var stateLabel: String {
        switch event.state {
        case .pending: return tr("ws.approval.pending")
        case .allowed: return tr("ws.approval.allowed")
        case .denied: return tr("ws.approval.denied")
        default: return tr("ws.approval.expired")
        }
    }
}
