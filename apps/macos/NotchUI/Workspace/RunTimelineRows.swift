import SwiftUI
import ImageIO

// The rows of a session's timeline (messages, thinking, tool calls, approvals), shared by the session views.

struct EventRow: View {
    let event: RunEvent
    /// The answer that ends its turn: only it has the footer (copy and time), as in an agent's own transcript.
    var final = true
    /// What came with the answer (the turn's changed files), inside the reply above its footer.
    var extras: AnyView? = nil
    /// Answers a question at the end of the reply when one of its options is tapped; nil when it cannot be answered.
    var onChoose: ((String) -> Void)? = nil
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
            // Each turn starts as its own block, as in the Nook chat and an agent's transcript.
            TranscriptUserMessage(text: event.text, date: event.date)
                .padding(.top, TranscriptStyle.turnGap - NookTheme.Spacing.sm)
                .padding(.bottom, NookTheme.Spacing.xxs)

        case .assistant:
            let background = BackgroundWork.notice(event.text)
            if background.isEmpty {
                TranscriptReply(text: event.text, date: event.date, footer: final, onChoose: onChoose) {
                    if let extras { extras }
                }
                // Room under a turn's final answer before the next one, as in an agent's own transcript.
                .padding(.bottom, final ? NookTheme.Spacing.lg : NookTheme.Spacing.xxs)
            } else {
                // "task-148 has been launched in the background…": a quiet line, as a command is.
                TranscriptWorkLine(symbol: "clock.arrow.circlepath", label: tr("ws.event.background", background.joined(separator: ", ")))
                    .help(event.text)
            }

        case .thinking:
            // The agent's reasoning, as in an agent's own transcript: its headline, live while it is written, the whole of
            // it a click away.
            TranscriptThought(text: event.text, open: expanded, live: event.state == .running, toggle: toggle)

        case .tool where Subagents.isLaunch(event):
            SubagentRow(event: event, expanded: expanded, toggle: toggle)

        case .tool where directory != nil && SharedFiles.isShare(event):
            SharedFilesRow(input: AgentActivity.input(event.detail) ?? [:], directory: directory ?? "", showFile: showFile,
                           shownFile: shownFile)

        case .tool:
            if let showFile, let file = ToolRow.file(event, in: directory) {
                ToolRow(event: event, expanded: false, toggle: { showFile(file) }, file: file, reveals: file == shownFile)
            } else {
                ToolRow(event: event, expanded: expanded, toggle: toggle)
            }

        case .fileChange:
            TranscriptWorkLine(symbol: "doc.badge.ellipsis", label: tr("ws.change." + (event.tool ?? "modified")),
                               detail: event.text, mono: true, link: "arrow.up.right.square") {
                openFile(event.detail ?? event.text)
            }
            .help(tr("ws.change.openDiff"))

        case .approval:
            ApprovalRow(event: event, expanded: expanded, toggle: toggle, decide: decide)

        case .error:
            TimelineProblemCard(text: event.text)

        case .system where event.tool == "handoff":
            // What the new agent was given: a summary you can read, not a hidden prompt.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                TranscriptWorkLine(symbol: "arrow.triangle.swap", label: event.text, open: expanded, action: toggle)
                if expanded {
                    Text(event.detail ?? "")
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, TranscriptStyle.workIndent)
                        .padding(.bottom, NookTheme.Spacing.xs)
                }
            }

        case .system where event.tool == "wake":
            // The agent picks up what it left running in the background: a turn of its own starts here.
            TranscriptWorkLine(symbol: "arrow.turn.down.right", label: event.text)
                .padding(.top, NookTheme.Spacing.sm)
                .help(event.text)

        case .system:
            TranscriptWorkLine(symbol: event.tool == "launch" ? "terminal" : "info.circle", label: event.text,
                               mono: event.tool == "launch")
                .help(event.text)

        case .result:
            // The end of a turn says nothing of its own: the fold above already says how long it worked, as in an agent's
            // own transcript. Only a turn that failed gets a line.
            if event.state == .failed {
                TranscriptWorkLine(symbol: "xmark.circle",
                                   label: event.text.isEmpty ? tr("ws.event.turnDone") : tr("ws.event.turnDoneWith", event.text),
                                   failed: true)
            }
        }
    }
}

/// Files the agent handed you (SharedFiles), as their own row: what it said with them, then each file as itself. A video
/// plays right here (and opens big from its enlarge button), a picture shows small, and any file opens in the side panel.
struct SharedFilesRow: View {
    /// The call's input (`SharedFiles.paths`, `SharedFiles.caption`).
    let input: [String: Any]
    /// The folder the files' relative paths resolve in.
    let directory: String
    var showFile: ((String) -> Void)? = nil
    var shownFile: String? = nil

    var body: some View {
        let paths = SharedFiles.paths(input).map { SessionOutputs.resolve($0, in: directory) }
        let videos = paths.filter { SessionOutputs.kind(path: $0) == .video && FileManager.default.fileExists(atPath: $0) }
        let others = paths.filter { !videos.contains($0) }
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TranscriptWorkLine(symbol: "paperclip", label: SharedFiles.caption(input) ?? tr("ws.shared.title"))
                .help(paths.map(AgentPathFormat.tilde).joined(separator: "\n"))
            ForEach(videos, id: \.self) { path in
                VideoTile(url: URL(fileURLWithPath: path), poster: nil, name: URL(fileURLWithPath: path).lastPathComponent,
                          maxHeight: 420)
            }
            if !others.isEmpty {
                ChipFlow(spacing: NookTheme.Spacing.sm) {
                    ForEach(others, id: \.self) { path in
                        SharedFileTile(path: path, shown: path == shownFile) { open(path) }
                    }
                }
            }
        }
        .padding(.leading, TranscriptStyle.workIndent)
        .padding(.vertical, NookTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// In the side panel when the session has one, else in its own app.
    private func open(_ path: String) {
        if let showFile { showFile(path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
}

/// One file in `SharedFilesRow` that is not a video: a picture as a small thumbnail, anything else as its icon and name.
private struct SharedFileTile: View {
    let path: String
    let shown: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var name: String { URL(fileURLWithPath: path).lastPathComponent }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 96)
                        .clipped()
                    NookDivider()
                }
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: OutputText.symbol(SessionOutputs.kind(path: path) ?? .document))
                        .font(NookTheme.font(10.5, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(name)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(shown || hovering ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, NookTheme.Spacing.sm)
                .padding(.vertical, NookTheme.Spacing.xs)
                .frame(maxWidth: thumbnail == nil ? 220 : 140, alignment: .leading)
            }
            .background(NookTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .strokeBorder(shown ? NookTheme.iris : NookTheme.fieldStroke)
            )
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("ws.shared.show") + " · " + AgentPathFormat.tilde(path))
        .accessibilityLabel(name)
        .task(id: path) {
            guard SessionOutputs.kind(path: path) == .image else { return }
            // A small picture made off the main thread: the shared file is often a full-size render.
            let url = URL(fileURLWithPath: path) as CFURL
            let small = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 400]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            thumbnail = small.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }
}

/// A subagent the agent started, as its own row: "Subagent running · Audit the chats" shimmering while it works (also in
/// the background after the turn), with its kind and time; it opens to its task and its answer.
struct SubagentRow: View {
    let event: RunEvent
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        if let agent = Subagents.list([event]).first {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    // A live line shimmers its label only, so the title goes into it while the subagent works.
                    TranscriptWorkLine(symbol: "person.2", label: agent.isRunning ? label(agent) + " · " + agent.title : label(agent),
                                       detail: agent.isRunning ? nil : agent.title, failed: agent.failed,
                                       live: agent.isRunning, open: expanded, quietChevron: !agent.isRunning, action: toggle)
                    SubagentElapsed(agent: agent)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        Text(agent.kind + (agent.background ? " · " + tr("ws.subagent.background") : ""))
                            .font(NookTheme.mono(10.5, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                        if !agent.prompt.isEmpty {
                            Text(agent.prompt)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                                .lineLimit(12)
                        }
                        if let answer = agent.answer {
                            MarkdownView(text: answer, size: 12.5)
                        }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TranscriptStyle.workIndent)
                    .padding(.bottom, NookTheme.Spacing.xs)
                }
            }
        }
    }

    private func label(_ agent: SubagentInfo) -> String {
        if agent.isRunning { return tr(agent.background ? "ws.subagent.runningBackground" : "ws.subagent.running") }
        return tr(agent.failed ? "ws.subagent.failed" : "ws.subagent.done")
    }
}

/// A problem in a conversation's timeline, on `surface`: an error (the coral symbol and its words in soft coral) or a usage
/// limit (an amber symbol, the words in the text ramp, and what the agent said under them). The same card in a session
/// Nook runs and in an agent's own transcript.
struct TimelineProblemCard: View {
    var symbol = "exclamationmark.octagon.fill"
    var tint = NookTheme.coral
    let text: String
    var detail: String? = nil

    private var isError: Bool { tint == NookTheme.coral }

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Text(text)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(isError ? NookTheme.coralSoft : NookTheme.textStrong)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.surface))
    }
}

/// A tool call, drawn as a step of an agent's own transcript (`TranscriptWorkLine`, `TranscriptStepDetail`): one line,
/// expandable to inspect input and output. A call that read or wrote a file instead opens that file in the side panel
/// (`file`).
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
        // The same line as a step in an agent's own transcript: what the agent did as a verb, then what it did that to.
        let step = AgentToolStep(event: event)
        let text = TranscriptStepText.parts(step)
        let tasks = step.tasks.flatMap { $0.isEmpty ? nil : $0 }
        let input = step.command ?? event.detail.flatMap { $0.isEmpty || $0 == "{}" ? nil : $0 }
        let opens = file == nil && (tasks != nil || input != nil || step.output != nil)
        let failed = step.state == .failed
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: text.verb, detail: text.detail, mono: text.mono,
                               failed: failed, checks: Verification.check(event).map { [$0] } ?? [], lines: step.lines,
                               open: opens ? expanded : nil, reveals: file == nil ? nil : reveals, quietChevron: true,
                               action: toggle)
                .help(file.map { tr("ws.file.show") + " · " + AgentPathFormat.tilde($0) } ?? event.text)
                .accessibilityLabel(event.text)
            // An MCP app is there to be used: shown whether or not the call is open.
            if let app = McpUI.resource(in: event.output) {
                McpAppBlock(resource: app, event: event).padding(.leading, TranscriptStyle.workIndent)
            }
            // Why it failed, right under it, then what it opens to.
            TranscriptStepDetail(error: step.error, open: expanded && file == nil, command: tasks == nil ? input : nil,
                                 output: tasks == nil ? step.output : nil, failed: failed, tasks: tasks)
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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack {
                Text(title).font(NookTheme.TextStyle.caption).foregroundStyle(WS.tertiary)
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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("ws.approval.asks", McpToolName(event.tool ?? "")?.toolLabel ?? event.tool ?? "tool"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(WS.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(event.text).font(NookTheme.mono(11.5)).foregroundStyle(WS.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Text(stateLabel).font(NookTheme.TextStyle.label).foregroundStyle(color).lineLimit(1).fixedSize()
            }
            if expanded, let detail = event.detail {
                CodeBlock(title: tr("ws.tool.input"), text: detail)
            }
        }
        .padding(NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        // Calm: the state label carries the color, the row itself stays neutral.
        .cardBackground(NookTheme.surface, stroke: NookTheme.line2, radius: NookTheme.Radius.card, style: .continuous)
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
