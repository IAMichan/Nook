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
    /// "Edit from here" under a message of yours; nil where the session cannot go back to before it.
    var onEdit: (() -> Void)? = nil
    /// Opens a command the agent left running in the background in the bar above the composer, where it goes on; nil
    /// where there is no such bar.
    var showBackground: (() -> Void)? = nil
    /// What you chose on a suggested session's card (`SessionSuggestion`); nil where the card cannot act.
    var onSuggestion: ((SessionSuggestion.Choice) -> Void)? = nil

    /// Whether a failed turn's text says a usage limit stopped it (`FailureClassifier`, as the session's limit wait).
    static func isUsageLimit(_ text: String) -> Bool {
        if case .usageLimit = FailureClassifier.classify(FailureEvidence(isError: true, messageText: text)) { return true }
        return false
    }

    var body: some View {
        switch event.kind {
        case .user:
            // Each turn starts as its own block, as in the Nook chat and an agent's transcript.
            TranscriptUserMessage(text: event.text, date: event.date, steered: event.steer == .steer,
                                  promoted: event.steer == .promoted, steerStatus: event.steerStatus, onEdit: onEdit)
                .padding(.top, event.steer == nil ? TranscriptStyle.turnGap - NookTheme.Spacing.sm : NookTheme.Spacing.xs)
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

        case .tool where showBackground != nil && BackgroundCommands.isCommand(event):
            // The same command as the row in the bar above the composer: a line under it says it goes on there.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                ToolRow(event: event, expanded: expanded, toggle: toggle)
                BackgroundCommandLink(event: event) { showBackground?() }
            }

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

        case .error where Self.isUsageLimit(event.text):
            // A usage limit is something to wait out or switch away from, not a crash: the amber card the transcript
            // view shows for one, with the agent's own words under it.
            TimelineProblemCard(symbol: "hourglass", tint: NookTheme.amber, text: tr("agents.notice.limit"), detail: event.text)

        case .error:
            TimelineProblemCard(text: event.text)

        case .page:
            // A page the agent showed (`render_page`), sandboxed and at its own height.
            RenderedPageRow(event: event).equatable()

        case .system where event.tool == SessionSuggestion.tool:
            // A side task the agent suggests as a new session (`session_suggest`), as Claude's "New session" card.
            if let suggestion = SessionSuggestion(event: event) {
                SessionSuggestionCard(suggestion: suggestion, state: event.state, startedID: event.output, choose: onSuggestion)
            }

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

        case .system where event.tool == "switch" && event.change != nil:
            // Another agent, model or effort from here on.
            ModelSwitchDivider(change: event.change!)

        case .system where event.tool == "clear":
            // `/clear`: the agent starts a new conversation here and remembers nothing above the line.
            TimelineNewDivider(label: event.text)

        case .system where event.tool == "limit":
            // When the limit that stopped this turn frees up.
            TranscriptWorkLine(symbol: "hourglass", label: event.text)
                .help(event.text)

        case .system where event.tool == "resume":
            // Nook goes on by itself after a limit: on the same account at reset, or on the one you switched to.
            TranscriptWorkLine(symbol: "play.circle", label: event.text)
                .help(event.text)

        case .system where event.tool == "origin":
            // Another agent, a script or Nook Chat started this session (`NewRunConfig.startedBy`).
            TranscriptWorkLine(symbol: "arrow.turn.right.down", label: event.text)
                .help(event.text)

        case .system where CompactionProgress.isCompaction(event):
            // A compaction: live while the agent summarizes, then what it did (`CompactionProgress`).
            switch event.state {
            case .running?:
                TranscriptWorkLine(symbol: "arrow.down.right.and.arrow.up.left", label: tr("ws.activity.compacting"), live: true)
            case .failed?:
                TranscriptWorkLine(symbol: "arrow.down.right.and.arrow.up.left", label: tr("ws.event.compactionStopped"), failed: true)
            default:
                TranscriptWorkLine(symbol: "arrow.down.right.and.arrow.up.left", label: event.text)
                    .help(event.text)
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

/// Whether a path exists and is a folder, remembered for a few seconds: the timeline's rows ask on every redraw while the
/// agent streams, and a file system call per row per token adds up on the main thread. Short enough that a file the agent
/// is still writing shows up on a later redraw.
enum PathProbe {
    private static var known: [String: (exists: Bool, isDirectory: Bool, at: Date)] = [:]
    private static let lock = NSLock()
    private static let lifetime: TimeInterval = 3

    static func stat(_ path: String) -> (exists: Bool, isDirectory: Bool) {
        let now = Date()
        lock.lock()
        if let hit = known[path], now.timeIntervalSince(hit.at) < lifetime {
            lock.unlock()
            return (hit.exists, hit.isDirectory)
        }
        lock.unlock()
        var folder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &folder)
        lock.lock()
        if known.count > 2_000 { known.removeAll() }
        known[path] = (exists, folder.boolValue, now)
        lock.unlock()
        return (exists, folder.boolValue)
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
        let videos = paths.filter { SessionOutputs.kind(path: $0) == .video && PathProbe.stat($0).exists }
        let others = paths.filter { !videos.contains($0) }
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TranscriptWorkLine(symbol: "paperclip", label: SharedFiles.caption(input) ?? tr("ws.shared.title"))
                .help(paths.map(AgentPathFormat.tilde).joined(separator: "\n"))
            ForEach(videos, id: \.self) { path in
                VideoTile(url: URL(fileURLWithPath: path), poster: nil, name: (path as NSString).lastPathComponent,
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

/// The files a session's final answer names (`FileLink.mentions`) that are made to be seen (a picture, a page, a document,
/// a video), as tiles under it that open in the side panel, so a banner the agent rendered with a script is a click
/// away even though it was never handed over (`AnswerFiles.load`).
struct AnswerFilesRow: View {
    let paths: [String]
    @Environment(\.sessionSide) private var side

    var body: some View {
        ChipFlow(spacing: NookTheme.Spacing.sm) {
            ForEach(paths, id: \.self) { path in
                SharedFileTile(path: path, shown: path == side.shownFile) { side.showFile(path) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Which files an answer names exist and are worth seeing (`SessionOutputs.kind`), in its order, at most `limit`.
enum AnswerFiles {
    struct Found: Sendable {
        let path: String
        let modified: Date
    }

    /// Files that opened by themselves already. Kept per file, not per answer: every later message that names the
    /// same file (or an answer still streaming in) would open it again right after you closed it.
    @MainActor private static var opened: Set<String> = []

    /// The files `text` names in `base`, looked up off the main thread once a streaming answer pauses. A fresh answer
    /// (`date` under two minutes ago) opens the first file its turn wrote in the side panel, unless a file or a tool
    /// panel you opened shows there.
    @MainActor
    static func load(_ text: String, date: Date?, base: String?, side: SessionSideLink) async -> [String] {
        guard let base, !base.isEmpty else { return [] }
        try? await Task.sleep(for: .milliseconds(500))
        let mentioned = FileLink.mentions(in: text).filter { SessionOutputs.kind(path: $0.path) != nil }
        guard !Task.isCancelled, !mentioned.isEmpty else { return [] }
        let all = await Task.detached(priority: .utility) { viewable(mentioned, base: base) }.value
        guard !Task.isCancelled else { return [] }
        // Written in this turn (or close to it): a Markdown file only counts then, so a coding answer that names
        // `README.md` gets no tile, and only such a file opens by itself.
        let since = (date ?? Date()).addingTimeInterval(-30 * 60)
        let found = all.filter { SessionOutputs.kind(path: $0.path) != .document || $0.modified > since }
        // A file gets one chance to open, taken or not: closed, or passed over while a panel showed, it stays closed.
        if let date, Date().timeIntervalSince(date) < 120,
           let made = found.first(where: { $0.modified > since }),
           opened.insert(made.path).inserted, side.shownFile == nil, !side.panelOpen {
            side.showFile(made.path)
        }
        return found.map(\.path)
    }

    static func viewable(_ targets: [FileTarget], base: String, limit: Int = 8) -> [Found] {
        var found: [Found] = []
        var seen: Set<String> = []
        for target in targets where SessionOutputs.kind(path: target.path) != nil {
            guard let resolved = FileLink.find(target, base: base), seen.insert(resolved.path).inserted,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            found.append(Found(path: resolved.path, modified: attributes[.modificationDate] as? Date ?? .distantPast))
            if found.count == limit { break }
        }
        return found
    }
}

/// One file in `SharedFilesRow` that is not a video: a picture as a small thumbnail, anything else as its icon and name.
/// `compact`, a picture the agent only looked at (`ViewedImagesRow`): the thumbnail alone, small, its name on hover.
struct SharedFileTile: View {
    let path: String
    let shown: Bool
    var compact = false
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        Button(action: action) {
            if compact { compactLabel } else { label }
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .help(tr(compact ? "ws.viewed.show" : "ws.shared.show") + " · " + AgentPathFormat.tilde(path))
        .accessibilityLabel(name)
        .task(id: path) {
            guard SessionOutputs.kind(path: path) == .image else { return }
            // A small picture made off the main thread: the shared file is often a full-size render.
            let url = URL(fileURLWithPath: path) as CFURL
            let size = compact ? 160 : 400
            let small = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: size]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            thumbnail = small.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
    }

    /// The thumbnail alone, 64 by 44 points; the picture's mark while it loads.
    private var compactLabel: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(icon: OutputText.symbol(.image))
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .frame(width: 64, height: 44)
        .clipped()
        .background(NookTheme.surface)
        .roundedClip(NookTheme.Radius.control)
        .roundedStrokeBorder(shown ? NookTheme.iris : (hovering ? NookTheme.line2 : NookTheme.fieldStroke), radius: NookTheme.Radius.control)
        .contentShape(Rectangle())
    }

    private var label: some View {
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
                Image(icon: OutputText.symbol(SessionOutputs.kind(path: path) ?? .document))
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
        .roundedClip(NookTheme.Radius.card)
        .roundedStrokeBorder(shown ? NookTheme.iris : NookTheme.fieldStroke, radius: NookTheme.Radius.card)
        .fixedSize()
        .contentShape(Rectangle())
    }
}

/// Pictures the agent only looked at (`ViewedImages`), under the step or the group of steps that read them: one row of
/// small thumbnails, at most `ViewedImages.rowLimit` and a count for the rest, so a run of screenshots never floods the
/// conversation. Each opens beside the conversation (in a window of its own where there is no side panel).
struct ViewedImagesRow: View {
    /// Absolute paths; the ones not on this Mac (any more) are left out.
    let paths: [String]
    @Environment(\.sessionSide) private var side

    var body: some View {
        let found = paths.filter { PathProbe.stat($0).exists }
        if !found.isEmpty {
            let shown = Array(found.prefix(ViewedImages.rowLimit))
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(shown, id: \.self) { path in
                    SharedFileTile(path: path, shown: path == side.shownFile, compact: true) { open(path) }
                }
                if found.count > shown.count {
                    Text(tr("ws.viewed.more", found.count - shown.count))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .help(found.dropFirst(shown.count).map(AgentPathFormat.tilde).joined(separator: "\n"))
                }
            }
            .padding(.leading, TranscriptStyle.workIndent)
            .padding(.bottom, NookTheme.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(tr("ws.viewed.title"))
        }
    }

    private func open(_ path: String) {
        if side.hasPanel {
            side.showFile(path)
        } else {
            AppModel.shared.openFileInNook(FileTarget(path: path), beside: false)
        }
    }
}

/// A subagent the agent started, as its own row: "Subagent running · Audit the chats" shimmering while it works (also in
/// the background after the turn), with its kind and time; it opens to what it went through (`SubagentTranscript`).
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
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                        SubagentMeta(agent: agent)
                        SubagentTranscript(agent: agent)
                    }
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

/// A problem in a conversation's timeline, as a row lined up with the work lines: an error (the coral symbol and its words in soft coral) or a usage
/// limit (an amber symbol, the words in the text ramp, and what the agent said under them). The same row in a session
/// Nook runs and in an agent's own transcript.
struct TimelineProblemCard: View {
    var symbol = "exclamationmark.octagon.fill"
    var tint = NookTheme.coral
    let text: String
    var detail: String? = nil

    private var isError: Bool { tint == NookTheme.coral }

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            Image(icon: symbol)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(tint)
                .frame(width: TranscriptStyle.workIcon)
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
        .padding(.vertical, NookTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        guard !path.isEmpty, !PathProbe.stat(path).isDirectory else { return nil }
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
                                 output: tasks == nil ? step.output : nil, failed: failed, tasks: tasks,
                                 commandSyntax: step.command != nil ? .shell : nil)
        }
    }
}

struct CodeBlock: View {
    let title: String
    let text: String
    var failed = false
    /// The language to color the text in (a command line as shell, arguments as JSON); nil leaves it plain, unless the
    /// text carries terminal colors, which then show.
    var syntax: SyntaxLanguage? = nil
    /// The text's own height: the block is as tall as it, up to `maxHeight`, and scrolls beyond that.
    @State private var height: CGFloat = 0
    private let maxHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack {
                Text(title).font(NookTheme.TextStyle.caption).foregroundStyle(WS.tertiary)
                Spacer()
                CopyIconButton(tr("button.copy"), height: 18, width: 18) {
                    AnsiText.hasCodes(text) ? AnsiText.plain(text) : text
                }
            }
            // Both ways, at a fixed height: a long output (a whole file) scrolls inside the block instead of spilling
            // over the rows around it.
            ScrollView([.horizontal, .vertical], showsIndicators: height > maxHeight) {
                content
                    .font(NookTheme.mono(11))
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

    @ViewBuilder
    private var content: some View {
        if AnsiText.hasCodes(text) {
            Text(TerminalColors.attributed(text, base: failed ? NookTheme.coralSoft : NookTheme.textStrong))
        } else if !failed, let syntax, let colored = CodeBlockStyle.highlighted(text, syntax: syntax) {
            Text(colored)
        } else {
            Text(text).foregroundStyle(failed ? NookTheme.coralSoft : NookTheme.textStrong)
        }
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
        .cardBackground(NookTheme.surface, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
        .nookClickable()
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
