import SwiftUI
import AppKit

/// The whole conversation of a session from the agent's own transcript, laid out as a thread (see
/// TranscriptPresentation): your messages in a bubble on the right, the agent's answers as text on the left, its work as
/// quiet one-line rows in between, and a finished turn folded into "Worked for 1m 3s". While the agent works the
/// transcript is read again every couple of seconds; an earlier session is read once.
struct TranscriptConversation: View {
    let path: String
    let author: String
    let accent: Color
    /// The agent is working: keep reading and show that it is busy.
    var working = false
    /// Shown when the transcript gives nothing (yet).
    var fallback: [AgentChatMessage] = []
    var onReply: ((String) -> Void)? = nil
    var footer: String? = nil
    /// Reads the conversation from somewhere else than a transcript file (a session in the cloud); nil when it could not.
    var load: (@Sendable () -> [AgentChatMessage]?)? = nil
    /// How often the conversation is read again while the agent works.
    var interval: UInt64 = 2_000_000_000
    @State private var messages: [AgentChatMessage] = []
    @State private var loaded = false
    /// The transcript `messages` belong to.
    @State private var readPath: String?
    /// The session's folder on this Mac, for the files the agent wrote; nil when they are not here (a cloud session).
    var directory: String? = nil
    /// Folds, groups and thoughts you opened.
    @State private var open: Set<String> = []
    /// A file the agent read or wrote that you clicked: shown beside the conversation.
    @State private var preview: String?
    /// How wide the results are: drag the line beside them, double-click it to reset. Remembered, as in a Nook session.
    @AppStorage("nook.agents.outputsWidth") private var outputsWidth = PanelLayout.outputs
    @State private var totalWidth: Double = 0
    /// The diff panel's choice of turn and file; nil while it is closed.
    @State private var diff: TurnDiffSelection?
    /// Follows the end while the agent writes, until you scroll away; then a pill brings you back.
    @State private var scroll = ScrollModel()
    @State private var atEnd = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var derived = TranscriptDerived()

    private var shown: [AgentChatMessage] { messages.isEmpty ? fallback : messages }

    var body: some View {
        let _ = derived.update(shown, working: working, directory: directory)
        let rows = derived.rows
        // Only the very last answer can still be answered by tapping one of its options.
        let answerable = working ? nil : shown.last(where: { $0.kind == .assistant })?.id
        let outputs = derived.outputs
        let turns = derived.turns
        // A turn still at work gets its card when it is done.
        let lastPrompt = shown.last(where: { $0.kind == .user })?.id
        let cards = Dictionary(turns.filter { !(working && $0.id == lastPrompt) }.compactMap { turn in turn.answerID.map { ($0, turn) } },
                               uniquingKeysWith: { first, _ in first })
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    // Lazy: a long conversation only lays out what is on screen.
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        if shown.isEmpty {
                            if loaded || (path.isEmpty && load == nil) {
                                Text(tr("agents.noMessagesInTranscript"))
                                    .font(NookTheme.TextStyle.body)
                                    .foregroundStyle(NookTheme.textTertiary)
                            } else {
                                // Most transcripts are read in a moment: nothing shows unless it takes longer.
                                PatientSpinner().frame(height: 160)
                            }
                        }
                        ForEach(rows) { row in
                            self.row(row, answerable: answerable, cards: cards).id(row.id)
                        }
                        if let footer {
                            Text(footer)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(.top, NookTheme.Spacing.xs)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .chatColumn()
                    .padding(.vertical, NookTheme.Spacing.xs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Open at the newest message; the transcript loads after the view appears, so also follow it once it arrives.
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
                } action: { _, nowAtEnd in
                    atEnd = nowAtEnd
                    if nowAtEnd { scroll.reachedEnd() }
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase = phase
                    if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
                }
                // A drag that began at the end, or the scroll wheel, leaves the end while you scroll: stop following.
                .onChange(of: atEnd) { _, now in
                    if !now, scrollPhase != .idle && scrollPhase != .animating { scroll.userScrolled() }
                }
                .overlay(alignment: .bottom) {
                    if scroll.mode == .free, !atEnd, !shown.isEmpty {
                        TimelineToEndPill {
                            scroll.jumpedToEnd()
                            withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .padding(.bottom, NookTheme.Spacing.md)
                    }
                }
                // Only while you are at the end: reading higher up, new messages do not pull you down.
                .onChange(of: shown) { _, _ in if scroll.shouldFollowEnd { scrollToEnd(proxy) } }
                .onChange(of: loaded) { _, _ in scrollToEnd(proxy) }
                .onAppear {
                    scrollToEnd(proxy)
                    DispatchQueue.main.async { scrollToEnd(proxy) }
                }
            }
            if let selection = diff, !turns.isEmpty {
                TurnDiffPanel(turns: turns, selection: Binding(get: { diff ?? selection }, set: { diff = $0 }),
                              directory: directory, wide: PanelLayout.wide($outputsWidth)) {
                    withAnimation(NookTheme.reveal) { diff = nil }
                }
                .resizablePanel(width: $outputsWidth, defaultWidth: PanelLayout.outputs, minimum: PanelLayout.minimumPanel,
                                available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .leading)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let preview {
                FilePreviewPanel(path: preview, wide: PanelLayout.wide($outputsWidth)) {
                    withAnimation(NookTheme.reveal) { self.preview = nil }
                }
                .id(preview)
                .resizablePanel(width: $outputsWidth, defaultWidth: PanelLayout.outputs, minimum: PanelLayout.minimumPanel,
                                available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .leading)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        // A file the agent links to (`src/app.swift:12`) opens in your editor at that line.
        .environment(\.fileLinkBase, directory)
        // What the agent produced goes to the outputs tab of the side panel around the conversation (`SessionWorkbench`).
        .preference(key: SessionOutputsReport.self, value: SessionOutputsReport(outputs: outputs))
        // ⌘D: the latest turn's diff; again to close it.
        .keyCommand("diff.toggle", enabled: !turns.isEmpty) {
            withAnimation(NookTheme.reveal) {
                if diff != nil {
                    diff = nil
                } else if let last = turns.last {
                    openDiff(TurnDiffSelection(turn: last.id))
                }
            }
        }
        .task(id: path + (working ? "#working" : "")) {
            // Another session in the same place: its conversation as read last time shows at once (never the previous
            // session's), and the read below brings it up to date.
            if readPath != path {
                readPath = path
                messages = TranscriptCache.messages(path) ?? []
                loaded = !messages.isEmpty
            }
            while !Task.isCancelled {
                let path = self.path
                // The first read is what you wait for; later ones follow a working agent in the background.
                let priority: TaskPriority = loaded ? .utility : .userInitiated
                if let load = self.load {
                    // Without an answer the conversation already shown stays.
                    if let fresh = await Task.detached(priority: priority, operation: { load() }).value, fresh != messages { messages = fresh }
                } else if !path.isEmpty {
                    let fresh = await Task.detached(priority: priority) { AgentTranscript.recent(path: path) }.value
                    if fresh != messages { messages = fresh }
                }
                guard !Task.isCancelled, readPath == path else { break }
                TranscriptCache.store(messages, path)
                loaded = true
                // An earlier session does not change any more: read once.
                guard working else { break }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ row: TranscriptRow, answerable: String?, cards: [String: TurnDiff]) -> some View {
        if case .fold(let id, let seconds, let inner) = row {
            let key = "fold:" + id
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                TranscriptFoldLine(text: seconds.map { tr("ws.fold.worked", AgentPathFormat.duration($0)) } ?? tr("agents.timeline.worked"),
                                   open: open.contains(key),
                                   checks: Verification.latest(TranscriptPresentation.steps(inner).compactMap(Verification.check))) { toggle(key) }
                if open.contains(key) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        ForEach(inner) { flatRow($0, answerable: nil, cards: cards).id($0.id) }
                    }
                    .padding(.bottom, NookTheme.Spacing.xs)
                }
            }
            .padding(.bottom, NookTheme.Spacing.xxs)
        } else {
            flatRow(row, answerable: answerable, cards: cards)
        }
    }

    /// Every row but a fold (a fold holds only these).
    @ViewBuilder
    private func flatRow(_ row: TranscriptRow, answerable: String?, cards: [String: TurnDiff] = [:]) -> some View {
        switch row {
        case .user(let message):
            // Space above your message: each turn starts as its own block.
            TranscriptUserBubble(message: message)
                .padding(.top, NookTheme.Spacing.lg)
                .padding(.bottom, NookTheme.Spacing.xxs)
        case .assistant(let message, let isFinal):
            VStack(alignment: .leading, spacing: 0) {
                TranscriptAnswer(message: message, isFinal: isFinal,
                                 onChoose: message.id == answerable ? onReply : nil)
                // What the turn changed, under its answer: a click opens the diff beside the conversation.
                if let turn = cards[message.id] {
                    TurnChangesCard(turn: turn, directory: directory) { file in
                        openDiff(TurnDiffSelection(turn: turn.id, file: file))
                    }
                }
            }
            .padding(.bottom, isFinal ? NookTheme.Spacing.lg : NookTheme.Spacing.xxs)
        case .thinking(let message):
            thinking(message)
        case .step(let step):
            stepLine(step)
        case .group(let id, let steps, let thoughts):
            group(id: id, steps: steps, thoughts: thoughts)
        case .fold:
            EmptyView()
        case .working(let since):
            TranscriptWorkingLine(since: since)
        case .live(let step):
            // The agent's task list, live, and what it does now in words rather than a bare "Thinking…".
            let tasks = TranscriptPresentation.tasks(shown)
            let activity = step.map { AgentActivity.of($0) } ?? TranscriptPresentation.activity(shown)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                if let tasks { TaskChecklistCard(steps: tasks) }
                TranscriptWorkLine(symbol: AgentActivityText.symbol(activity),
                                   label: AgentActivityText.headline(activity, step: tasks.flatMap(TaskChecklist.activeStep)),
                                   live: true)
                    .help(step.map(Self.label) ?? "")
            }
        case .interrupted:
            TranscriptWorkLine(symbol: "stop.circle", label: tr("agents.transcript.interrupted"))
                .padding(.bottom, NookTheme.Spacing.md)
        }
    }

    private func group(id: String, steps: [AgentToolStep], thoughts: [String: [AgentChatMessage]]) -> some View {
        let key = "group:" + id
        let tally = ToolTally(steps: steps)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(tally), label: ToolTallyText.sentence(tally),
                               failed: tally.failed, checks: tally.checks, open: open.contains(key)) { toggle(key) }
            if open.contains(key) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(steps) { step in
                            ForEach(thoughts[step.id] ?? []) { thinking($0) }
                            stepLine(step)
                        }
                    }
                }
                // A step that joins the group during a live turn stays in view at the end of the short scroll.
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .frame(maxHeight: 288)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One step. A step that set the agent's task list (TodoWrite, update_plan) opens to that list; a step that read or
    /// wrote a file on this Mac opens that file in the side panel.
    private func stepLine(_ step: AgentToolStep) -> some View {
        let key = "plan:" + step.id
        let tasks = step.tasks.flatMap { $0.isEmpty ? nil : $0 }
        let file = tasks == nil ? directory.flatMap { folder in step.file.map { SessionOutputs.resolve($0, in: folder) } } : nil
        let text = TranscriptStepText.parts(step)
        let error = step.state == .failed ? step.error : nil
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: text.verb, detail: text.detail, mono: text.mono,
                               failed: step.state == .failed, checks: Verification.check(step).map { [$0] } ?? [],
                               open: tasks == nil ? nil : open.contains(key), reveals: file.map { $0 == preview }) {
                if let file { show(file) } else { toggle(key) }
            }
            .help(file.map { tr("ws.file.show") + " · " + AgentPathFormat.tilde($0) } ?? Self.label(step))
            // Why it failed, right under it: what the agent ran into before it tried something else.
            if let error {
                Text(error)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, NookTheme.Spacing.xxl + NookTheme.Spacing.sm)
                    .padding(.bottom, NookTheme.Spacing.xxs)
                    .help(error)
            }
            if let tasks, open.contains(key) {
                TaskListRows(steps: tasks)
                    .padding(NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
                    .padding(.leading, 26)
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
        }
    }

    /// The agent's reasoning on one line, the whole of it a click away.
    private func thinking(_ message: AgentChatMessage) -> some View {
        let key = "think:" + message.id
        let headline = TranscriptPresentation.headline(message.text)
        let more = headline != message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            TranscriptWorkLine(symbol: "brain", label: headline.isEmpty ? tr("agents.thought") : headline,
                               open: more ? open.contains(key) : nil) { if more { toggle(key) } }
            if more, open.contains(key) {
                Text(message.text)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
        }
    }

    /// "Ran  npm test": what the agent did, then what it did that to.
    private static func label(_ step: AgentToolStep) -> String {
        let text = TranscriptStepText.parts(step)
        return text.detail.isEmpty ? text.verb : text.verb + "  " + text.detail
    }

    private func toggle(_ key: String) {
        withAnimation(NookTheme.reveal) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }

    /// Opens a file in the side panel; the file that is open already closes again.
    private func show(_ file: String) {
        withAnimation(NookTheme.reveal) {
            preview = preview == file ? nil : file
            diff = nil
        }
    }

    /// Opens the diff panel on a turn (and a file), in place of a file.
    private func openDiff(_ selection: TurnDiffSelection) {
        withAnimation(NookTheme.reveal) {
            preview = nil
            diff = selection
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard !shown.isEmpty || footer != nil else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

/// The rows, outputs and turn diffs of a conversation, worked out again only when its messages change. The view's body
/// runs far more often (a scroll starting and stopping, the side panel resizing, a fold opening), and each of these walks
/// the whole transcript. Comparing the same array again is cheap: Swift sees it is the same storage.
@MainActor
private final class TranscriptDerived {
    private var key: (messages: [AgentChatMessage], working: Bool, directory: String?)?
    private(set) var rows: [TranscriptRow] = []
    private(set) var outputs: [SessionOutput] = []
    private(set) var turns: [TurnDiff] = []

    func update(_ messages: [AgentChatMessage], working: Bool, directory: String?) {
        if let key, key.working == working, key.directory == directory, key.messages == messages { return }
        key = (messages, working, directory)
        rows = TranscriptPresentation.rows(messages, working: working)
        outputs = SessionOutputs.collect(messages, directory: directory ?? "").filter { directory != nil || !$0.isFile }
        turns = TurnDiff.collect(messages)
    }
}

// MARK: Messages

/// What you wrote: a soft bubble on the right, at most four fifths wide. A long message folds to its first lines;
/// on hover its time and a copy button appear under it.
struct TranscriptUserBubble: View {
    let message: AgentChatMessage
    @State private var expanded = false
    @State private var hovering = false

    /// The words, without the paths of the pictures sent along; those show as pictures above the bubble.
    private var parts: (text: String, images: [URL]) { ImageAttachment.splittingPaths(from: message.text) }

    private var long: Bool {
        let text = parts.text
        return text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    var body: some View {
        let parts = parts
        VStack(alignment: .trailing, spacing: NookTheme.Spacing.xs) {
            // Sent while the agent was working: it changed course mid-turn (a steer mark).
            if message.queued {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(tr("agents.message.steered"))
                }
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
            }
            if !parts.images.isEmpty {
                MessagePictures(urls: parts.images)
            }
            if !parts.text.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 64)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        text(parts.text)
                        if long {
                            Button(expanded ? tr("agents.message.showLess") : tr("agents.message.showFull")) {
                                withAnimation(NookTheme.reveal) { expanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    .padding(NookTheme.Spacing.md)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.bubble, style: .continuous).fill(NookTheme.bubble))
                }
            }
            HStack(spacing: NookTheme.Spacing.md) {
                if let date = message.date { TranscriptTime(date: date) }
                TranscriptCopyButton(text: message.text)
            }
            .opacity(hovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func text(_ string: String) -> some View {
        let label = Text(string)
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if long && !expanded {
            label
                .frame(maxHeight: 176, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
        } else {
            label
        }
    }
}

/// The agent's answer: formatted text on the left without a bubble. The final answer of a turn shows its copy button
/// and time on hover.
struct TranscriptAnswer: View {
    let message: AgentChatMessage
    let isFinal: Bool
    var onChoose: ((String) -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            MarkdownView(text: message.text, size: 13, onChoose: onChoose)
            if isFinal {
                HStack(spacing: NookTheme.Spacing.md) {
                    TranscriptCopyButton(text: message.text)
                    if let date = message.updated ?? message.date { TranscriptTime(date: date) }
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// "14:03" today, "12 Oct 14:03" before; the full date on hover.
struct TranscriptTime: View {
    let date: Date

    var body: some View {
        let text = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(date.formatted(date: .complete, time: .shortened))
    }
}

/// Copies a message; the icon turns into a check for a moment.
struct TranscriptCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(NookTheme.font(10.5, .semibold))
                .foregroundStyle(copied ? NookTheme.mint : NookTheme.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("button.copy"))
        .accessibilityLabel(tr("button.copy"))
    }
}

// MARK: Work

/// One line of the agent's work: an icon, what it did in muted text, and a chevron when it opens. The line that runs now
/// shimmers.
struct TranscriptWorkLine: View {
    let symbol: String
    let label: String
    /// What the work was done to (a command, a file, a pattern), after the label in quieter text; in monospace with `mono`.
    var detail: String? = nil
    var mono = false
    var failed = false
    var live = false
    /// The tests, builds and linters it stands for, and how they went.
    var checks: [VerificationCheck] = []
    /// The lines its edits added and removed.
    var lines: EditLines? = nil
    /// Nil: the line does not open.
    var open: Bool? = nil
    /// Nil: the line has no file to show; true while its file is open in the side panel.
    var reveals: Bool? = nil
    var action: (() -> Void)? = nil
    @State private var hovering = false

    private var clickable: Bool { open != nil || reveals != nil }

    /// The label, then its detail on the same line, so a long command or path truncates as one sentence.
    private var labelText: Text {
        let color = reveals == true ? NookTheme.paper : hovering && clickable ? NookTheme.textSecondary : NookTheme.textTertiary
        let head = Text(label).foregroundStyle(color)
        guard let detail, !detail.isEmpty else { return head }
        return head + Text(" ") + Text(detail)
            .font(mono ? NookTheme.mono(12) : NookTheme.TextStyle.body)
            .foregroundStyle(color)
    }

    var body: some View {
        let content = HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: failed ? "exclamationmark.circle" : symbol)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(failed ? NookTheme.coral.opacity(0.6) : NookTheme.textTertiary)
                .frame(width: 24)
            if live {
                ShimmerText(text: label)
                    .lineLimit(1)
            } else {
                labelText
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let open {
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(9, .bold))
                    .foregroundStyle(NookTheme.textTertiary.opacity(0.7))
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            if failed {
                Image(systemName: "xmark").font(NookTheme.font(9, .bold)).foregroundStyle(NookTheme.coral.opacity(0.6))
            }
            if let reveals {
                Image(systemName: "sidebar.right")
                    .font(NookTheme.font(9.5, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(reveals || hovering ? 1 : 0)
            }
            if let lines { EditLinesLabel(lines: lines, size: 11) }
            if !checks.isEmpty { VerificationChips(checks: checks) }
            Spacer(minLength: 0)
        }
        .font(NookTheme.TextStyle.body)
        .frame(minHeight: 24)
        .contentShape(Rectangle())

        if let action, clickable {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(open == true || reveals == true ? .isSelected : [])
        } else {
            content
        }
    }
}

/// A finished turn's work, folded: "Worked for 1m 3s ›" over a hairline.
struct TranscriptFoldLine: View {
    let text: String
    let open: Bool
    /// What the turn's tests and builds came to, in sight while its work is folded.
    var checks: [VerificationCheck] = []
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(text)
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(9, .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                if !checks.isEmpty { VerificationChips(checks: checks) }
                Spacer(minLength: 0)
            }
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(hovering ? NookTheme.paper.opacity(0.85) : NookTheme.textTertiary)
            .padding(.top, NookTheme.Spacing.xxs)
            .padding(.bottom, NookTheme.Spacing.md)
            .overlay(alignment: .bottom) { NookDivider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// Right under your message while the agent works: "Working for 12s", ticking, over a hairline.
struct TranscriptWorkingLine: View {
    let since: Date?

    var body: some View {
        Group {
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(tr("agents.timeline.workingFor", AgentPathFormat.duration(max(0, context.date.timeIntervalSince(since)))))
                        .monospacedDigit()
                }
            } else {
                Text(tr("ws.timeline.working"))
            }
        }
        .font(NookTheme.TextStyle.body)
        .foregroundStyle(NookTheme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, NookTheme.Spacing.xxs)
        .padding(.bottom, NookTheme.Spacing.md)
        .overlay(alignment: .bottom) { NookDivider() }
    }
}

/// How a step reads: what the agent did as a verb ("Ran", "Edited"), then what it did that to, instead of the bare
/// name of the tool. A tool Nook does not know keeps its own name.
enum TranscriptStepText {
    /// `detail` is the command, file, pattern or task; `mono` when it is code or a path rather than words.
    static func parts(_ step: AgentToolStep) -> (verb: String, detail: String, mono: Bool) {
        let summary = step.summary
        switch step.name {
        case "Task", "Agent": return (tr("agents.step.delegated"), summary, false)
        case "TodoWrite", "Plan", "update_plan": return (tr("agents.step.tasks"), "", false)
        case "ExitPlanMode": return (tr("agents.step.plan"), "", false)
        case "WebSearch", "web_search", "google_web_search": return (tr("agents.step.searchedWeb"), summary, false)
        case "WebFetch", "web_fetch": return (tr("agents.step.fetched"), summary, true)
        case "Skill": return (tr("agents.step.skill"), summary, true)
        default: break
        }
        let name = step.name.lowercased()
        switch ToolCategory.of(tool: step.name) {
        case .command:
            // A description says in words what the command does; without one the command line itself shows.
            let described = step.command.map { $0 != summary } ?? false
            return (tr("agents.step.ran"), summary, !described)
        case .edit:
            return (tr(["write", "write_file"].contains(name) ? "agents.step.wrote" : "agents.step.edited"), summary, true)
        case .read:
            return (tr(["ls", "list_directory"].contains(name) ? "agents.step.listed" : "agents.step.read"), summary, true)
        case .search:
            return (tr("agents.step.searched"), summary, true)
        case .other:
            return (step.name, summary, false)
        }
    }
}

/// The icon of a step, after the kind of work it does.
enum TranscriptSymbols {
    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Task", "Agent": return "person.2"
        case "TodoWrite", "Plan", "update_plan", "ExitPlanMode": return "checklist"
        case "WebSearch", "WebFetch", "web_search", "web_fetch", "google_web_search": return "globe"
        case "Skill": return "sparkles"
        default:
            switch ToolCategory.of(tool: tool) {
            case .command: return "terminal"
            case .edit: return "square.and.pencil"
            case .read: return "eye"
            case .search: return "magnifyingglass"
            case .other: return "wrench"
            }
        }
    }

    /// One kind of work keeps its own icon; mixed work gets a hammer.
    static func symbol(_ tally: ToolTally) -> String {
        let parts = tally.parts
        guard parts.count == 1, let category = parts.first?.category else { return "hammer" }
        switch category {
        case .command: return "terminal"
        case .edit: return "square.and.pencil"
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .other: return "wrench"
        }
    }
}

/// The conversations of the last transcripts read, by path, so opening a session again (or switching back to it) shows
/// its conversation at once instead of an empty panel until the file is read.
@MainActor
enum TranscriptCache {
    private static var byPath: [String: [AgentChatMessage]] = [:]
    private static var order: [String] = []
    private static let limit = 12

    static func messages(_ path: String) -> [AgentChatMessage]? { byPath[path] }

    static func store(_ messages: [AgentChatMessage], _ path: String) {
        guard !path.isEmpty, !messages.isEmpty else { return }
        byPath[path] = messages
        order.removeAll { $0 == path }
        order.append(path)
        while order.count > limit { byPath[order.removeFirst()] = nil }
    }
}
