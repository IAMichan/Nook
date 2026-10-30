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
    /// The composer (and what sits on it) under the conversation, which scrolls on behind it.
    var bottomBar: AnyView? = nil
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
    @Environment(\.sessionSide) private var sideLink
    /// Follows the end while the agent writes, until you scroll away; then a pill brings you back.
    @State private var scroll = ScrollModel()
    @State private var atEnd = true
    /// The conversation is taller than the view: only then the rail with your messages shows.
    @State private var overflows = false
    @State private var scrollPhase: ScrollPhase = .idle
    /// The rows on screen, for where you left the conversation; not state, so scrolling does not redraw it.
    @State private var onScreen = VisibleTimelineRows()
    /// Where you left this conversation last time (TimelineVisitStore), read as it opens.
    @State private var visit: TimelineVisit?
    /// The row the "New since your last visit" line sits above; decided once the conversation has loaded.
    @State private var newSince: String?
    /// The transcript was read fresh for this view (not only taken from the cache): what is new since shows then.
    @State private var freshRead = false
    @State private var derived = TranscriptDerived()

    private var shown: [AgentChatMessage] { messages.isEmpty ? fallback : messages }

    /// The session's key in TimelineVisitStore: its transcript; nil for a conversation read from elsewhere.
    private var visitKey: String? { path.isEmpty ? nil : "transcript:" + path }

    private var visitRows: [TimelineLanding.Row] {
        derived.rows.map { ($0.id, $0.visitDate) }
    }

    var body: some View {
        let _ = derived.update(shown, working: working, directory: directory)
        let rows = derived.rows
        // Only the very last answer can still be answered by tapping one of its options.
        let answerable = working ? nil : shown.last(where: { $0.kind == .assistant })?.id
        let outputs = derived.outputs
        let turns = derived.turns
        // A turn still at work gets its card when it is done (a message you sent while it worked is part of that turn).
        let lastPrompt = shown.last(where: { $0.kind == .user && !$0.queued })?.id
        let cards = Dictionary(turns.filter { !(working && $0.id == lastPrompt) }.compactMap { turn in turn.answerID.map { ($0, turn) } },
                               uniquingKeysWith: { first, _ in first })
        let beforeNew = newSince.flatMap { id in rows.firstIndex { $0.id == id } }.flatMap { $0 > 0 ? rows[$0 - 1].id : nil }
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                // No scroll bar, not even when the system shows them always: the rail beside it marks your messages.
                ScrollView {
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
                            if row.id == newSince {
                                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                                    TimelineNewDivider()
                                    self.row(row, answerable: answerable, cards: cards)
                                }
                                .id(row.id)
                            } else {
                                // The "new since" line is a hairline of its own: a fold right above it gives up its own.
                                self.row(row, answerable: answerable, cards: cards, ruled: row.id != beforeNew).id(row.id)
                            }
                        }
                        if let footer {
                            Text(footer)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(.top, NookTheme.Spacing.xs)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .scrollTargetLayout()
                    .chatColumn()
                    .padding(.vertical, NookTheme.Spacing.xs)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Open at the newest message; the transcript loads after the view appears, so also follow it once it arrives.
                .defaultScrollAnchor(.bottom)
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { ids in onScreen.ids = Set(ids) }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
                } action: { _, nowAtEnd in
                    atEnd = nowAtEnd
                    if nowAtEnd { scroll.reachedEnd() }
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, now in
                    overflows = now
                }
                .overlay(alignment: .trailing) {
                    if overflows, !derived.marks.isEmpty {
                        TranscriptPromptRail(marks: derived.marks) { mark in
                            scroll.userScrolled()
                            withAnimation(NookTheme.scroll) { proxy.scrollTo(mark.row, anchor: .top) }
                        }
                        .padding(.vertical, NookTheme.Spacing.md)
                        .transition(.opacity)
                    }
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase = phase
                    if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
                }
                // A drag that began at the end, or the scroll wheel, leaves the end while you scroll: stop following.
                .onChange(of: atEnd) { _, now in
                    if !now, scrollPhase != .idle && scrollPhase != .animating { scroll.userScrolled() }
                }
                // The conversation scrolls on behind the composer; the pill back to the end rides on top of it.
                .composerInset(spacing: bottomBar == nil ? 0 : NookTheme.Spacing.xxxl) {
                    (bottomBar ?? AnyView(Color.clear.frame(height: 0)))
                        .toEndPill(scroll.mode == .free && !atEnd && !shown.isEmpty) {
                            scroll.jumpedToEnd()
                            withAnimation(NookTheme.scroll) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                }
                // Only while you are at the end: reading higher up, new messages do not pull you down.
                .onChange(of: shown) { _, _ in if scroll.shouldFollowEnd { scrollToEnd(proxy) } }
                // Back where you left it: the end, what is new since, or the row you were reading (TimelineLanding).
                .onChange(of: freshRead) { _, read in if read { land(proxy) } }
                .onAppear {
                    visit = visitKey.flatMap { TimelineVisitStore.shared.visit(for: $0) }
                    if let visit { open = visit.open }
                    scrollToEnd(proxy)
                    DispatchQueue.main.async { scrollToEnd(proxy) }
                }
                .onDisappear { rememberVisit() }
            }
        }
        // Exactly the width it is given, however wide a row inside wants to be: measuring a row that runs past the window
        // would hand the panels more room than there is and push everything off both sides.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        // A file the agent links to (`src/app.swift:12`) opens in your editor at that line.
        .environment(\.fileLinkBase, directory)
        // What the agent produced goes to the outputs tab and diff panel of the side panel around the conversation (`SessionWorkbench`).
        .preference(key: SessionOutputsReport.self, value: SessionOutputsReport(outputs: outputs, turns: turns))
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
                freshRead = true
                // An earlier session does not change any more: read once.
                guard working else { break }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ row: TranscriptRow, answerable: String?, cards: [String: TurnDiff], ruled: Bool = true) -> some View {
        if case let (key, text, inner)? = Self.fold(row) {
            TranscriptFold(text: text, open: open.contains(key), checks: derived.foldChecks[row.id] ?? [], ruled: ruled,
                           toggle: { toggle(key) }) {
                ForEach(inner) { flatRow($0, answerable: nil, cards: cards).id($0.id) }
            }
        } else {
            flatRow(row, answerable: answerable, cards: cards)
        }
    }

    /// A fold's key, its line ("Worked for 1m 3s", "Continued for 20s") and the rows it holds; nil for any other row.
    private static func fold(_ row: TranscriptRow) -> (key: String, text: String, rows: [TranscriptRow])? {
        switch row {
        case .fold(let id, let seconds, let inner):
            return ("fold:" + id, seconds.map { tr("ws.fold.worked", AgentPathFormat.duration($0)) } ?? tr("agents.timeline.worked"), inner)
        case .continued(let id, let seconds, let inner):
            return ("continued:" + id,
                    seconds.map { tr("agents.timeline.continuedFor", AgentPathFormat.duration($0)) } ?? tr("agents.timeline.continued"), inner)
        default:
            return nil
        }
    }

    /// Every row but a fold (a fold holds only these).
    @ViewBuilder
    private func flatRow(_ row: TranscriptRow, answerable: String?, cards: [String: TurnDiff] = [:]) -> some View {
        switch row {
        case .user(let message):
            // Space above your message: each turn starts as its own block, as in the Nook chat.
            TranscriptUserMessage(text: message.text, date: message.date, steered: message.queued)
                .padding(.top, TranscriptStyle.turnGap - NookTheme.Spacing.sm)
                .padding(.bottom, NookTheme.Spacing.xxs)
        case .assistant(let message, let isFinal):
            // Only the final answer of a turn has the footer (copy and time).
            TranscriptReply(text: message.text, date: message.updated ?? message.date, footer: isFinal,
                            onChoose: message.id == answerable ? onReply : nil) {
                // What the turn changed, under its answer: a click opens the diff beside the conversation.
                if let turn = cards[message.id] {
                    TurnChangesCard(turn: turn, directory: directory) { file in
                        sideLink.openDiff(TurnDiffSelection(turn: turn.id, file: file))
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
        case .fold, .continued:
            EmptyView()
        case .notice(let message):
            TranscriptNotice(message: message)
        case .working(let since):
            TranscriptWorkingLine(since: since)
        case .live(let step, let thought):
            // The agent's task list, live, then why it does what it does now (the thought right before it) and what it
            // does in words rather than a bare "Thinking…".
            let activity = step.map { AgentActivity.of($0) }
                ?? (thought == nil ? TranscriptPresentation.activity(shown) : .thinking(""))
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                if let thought { thinking(thought) }
                TranscriptLiveLine(activity: activity, tasks: TranscriptPresentation.tasks(shown), help: step.map(Self.label))
            }
        case .interrupted(_, let seconds):
            TranscriptWorkLine(symbol: "stop.circle",
                               label: seconds.map { tr("agents.transcript.stoppedAfter", AgentPathFormat.duration($0)) }
                                   ?? tr("agents.transcript.interrupted"))
                .padding(.bottom, NookTheme.Spacing.md)
        }
    }

    private func group(id: String, steps: [AgentToolStep], thoughts: [String: [AgentChatMessage]]) -> some View {
        let key = "group:" + id
        let tally = ToolTally(steps: steps)
        return TranscriptWorkGroup(tally: tally, open: open.contains(key), toggle: { toggle(key) }) {
            ForEach(steps) { step in
                ForEach(thoughts[step.id] ?? []) { thinking($0) }
                stepLine(step)
            }
        }
    }

    /// One step. A step that set the agent's task list (TodoWrite, update_plan) opens to that list; a step that read or
    /// wrote a file on this Mac opens that file in the side panel; a command or another tool opens to its whole command
    /// line and what it gave back.
    private func stepLine(_ step: AgentToolStep) -> some View {
        let key = "step:" + step.id
        let tasks = step.tasks.flatMap { $0.isEmpty ? nil : $0 }
        let file = tasks == nil ? directory.flatMap { folder in step.file.map { SessionOutputs.resolve($0, in: folder) } } : nil
        // A command or another tool opens to its whole command line and what it gave back, as a tool call in a session
        // Nook runs does.
        let command = tasks == nil && file == nil ? TranscriptPresentation.fullCommand(step) : nil
        let output = tasks == nil && file == nil ? step.output : nil
        let opens = tasks != nil || command != nil || output != nil
        let text = TranscriptStepText.parts(step)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: text.verb, detail: text.detail, mono: text.mono,
                               failed: step.state == .failed, checks: Verification.check(step).map { [$0] } ?? [],
                               open: opens ? open.contains(key) : nil, reveals: file.map { $0 == sideLink.shownFile }, quietChevron: true) {
                if let file { sideLink.showFile(file) } else { toggle(key) }
            }
            .help(file.map { tr("ws.file.show") + " · " + AgentPathFormat.tilde($0) } ?? Self.label(step))
            // Why it failed, right under it, then what it opens to.
            TranscriptStepDetail(error: step.state == .failed ? step.error : nil, open: open.contains(key), command: command,
                                 output: output, failed: step.state == .failed, tasks: tasks)
        }
    }

    /// The agent's reasoning on one line, the whole of it a click away.
    private func thinking(_ message: AgentChatMessage) -> some View {
        let key = "think:" + message.id
        return TranscriptThought(text: message.text, open: open.contains(key)) { toggle(key) }
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

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard !shown.isEmpty || footer != nil else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// Once the conversation has loaded: what came in since your last visit (under its line), the row you were reading
    /// when you left, else the end. Following stops at a row, so what comes in does not pull you away from it.
    private func land(_ proxy: ScrollViewProxy) {
        let rows = visitRows
        newSince = visit.flatMap { TimelineLanding.firstNew(rows, since: $0.lastViewedAt) }
        switch TimelineLanding.decide(rows, visit: visit) {
        case .end:
            scrollToEnd(proxy)
        case .newSince(let id), .row(let id):
            scroll.userScrolled()
            proxy.scrollTo(id, anchor: .top)
            // After the other handlers of this change (following the end) and once the lazy rows are laid out.
            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
        }
    }

    /// Where you leave the conversation: the row at the top, what you opened, and whether you were at the end.
    private func rememberVisit() {
        guard let visitKey, loaded else { return }
        TimelineVisitStore.shared.remember(sessionID: visitKey, visit: TimelineVisit(
            anchorID: TimelineLanding.top(visitRows, visible: onScreen.ids), open: open, atEnd: atEnd, lastViewedAt: Date()))
    }
}

/// The ids of a timeline's rows on screen, kept out of SwiftUI's state: they change on every scroll, and only matter
/// when the conversation closes.
final class VisibleTimelineRows {
    var ids: Set<String> = []
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
    private(set) var marks: [PromptMark] = []
    /// The tests and builds each fold holds, by the fold's row id: reading every command again on each redraw of the
    /// timeline cost more than the rest of the row.
    private(set) var foldChecks: [String: [VerificationCheck]] = [:]

    func update(_ messages: [AgentChatMessage], working: Bool, directory: String?) {
        if let key, key.working == working, key.directory == directory, key.messages == messages { return }
        key = (messages, working, directory)
        rows = TranscriptPresentation.rows(messages, working: working)
        outputs = SessionOutputs.collect(messages, directory: directory ?? "").filter { directory != nil || !$0.isFile }
        turns = TurnDiff.collect(messages)
        marks = TranscriptPresentation.promptMarks(rows)
        foldChecks = [:]
        for row in rows {
            switch row {
            case .fold(_, _, let inner), .continued(_, _, let inner):
                foldChecks[row.id] = Verification.latest(TranscriptPresentation.steps(inner).compactMap(Verification.check))
            default: break
            }
        }
    }
}

/// Your messages as short marks along the edge of the conversation, where a scroll bar would be: each sits about where
/// the message is, a click scrolls to it, and hovering shows the prompt you wrote. The rail itself only shows while the pointer is over it.
struct TranscriptPromptRail: View {
    let marks: [PromptMark]
    let onSelect: (PromptMark) -> Void
    @State private var hovered: String?
    /// The pointer is over the rail: only then it shows, with a background so the marks stand out over the text.
    @State private var overRail = false

    private static let width: CGFloat = 28
    /// The height each mark can be clicked over.
    private static let target: CGFloat = 16

    var body: some View {
        ZStack {
            // A fully transparent view is not hit-tested, so this layer keeps the hidden rail hoverable.
            Color.clear.contentShape(Rectangle())
            marksLayer.opacity(overRail ? 1 : 0)
        }
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(DropdownStyle.panel)
                .opacity(overRail ? 0.92 : 0)
        )
        .onHover { overRail = $0 }
        .animation(NookTheme.hover, value: hovered)
        .animation(NookTheme.hover, value: overRail)
    }

    private var marksLayer: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.height - Self.target)
            ForEach(marks) { mark in
                let lit = hovered == mark.id
                Button { onSelect(mark) } label: {
                    Capsule()
                        .fill(lit ? NookTheme.paper : NookTheme.textTertiary)
                        .frame(width: lit ? 12 : 8, height: 2)
                        .frame(width: Self.width, height: Self.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverCard { PromptCard(text: Self.prompt(mark.text)) }
                .onHover { inside in
                    if inside { hovered = mark.id } else if hovered == mark.id { hovered = nil }
                }
                .position(x: Self.width / 2, y: Self.target / 2 + mark.position * travel)
            }
        }
    }

    /// What you wrote, without the pictures sent along, cut when it is too long for a card.
    private static func prompt(_ text: String) -> String {
        let words = ImageAttachment.splittingPaths(from: text).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.count > 600 ? String(words.prefix(599)) + "…" : words
    }
}

/// The prompt behind a mark on the rail, in a card beside it.
private struct PromptCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            .lineLimit(12)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(NookTheme.Spacing.lg)
            .frame(width: 300, alignment: .leading)
            .background(DropdownStyle.panel)
    }
}

// MARK: Messages

// Your messages and the agent's answers are the shared `TranscriptUserMessage` and `TranscriptReply`
// (NotchUI/Components/TranscriptMessage.swift), the same as in the Nook chat.

// MARK: Work

// The lines of the agent's work are the shared views in NotchUI/Components/TranscriptWork.swift, the same as in a
// session Nook runs.

/// Something that happened to the conversation, in sight also when its turn folds. A compaction is a quiet word across
/// the column with room around it, as a new day is in a chat ("Context compacted from 167k tokens"); an error or a usage
/// limit is the timeline's problem card, as in a session Nook runs.
struct TranscriptNotice: View {
    let message: AgentChatMessage

    var body: some View {
        switch message.notice {
        case .compacted(let tokens):
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                Text(tokens.map { tr("agents.notice.compactedFrom", TokenTally.format($0)) } ?? tr("agents.notice.compacted"))
                    .lineLimit(1)
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, NookTheme.Spacing.md)
            .accessibilityElement(children: .combine)
        case .limit(let text, let resets):
            TimelineProblemCard(symbol: "hourglass", tint: NookTheme.amber,
                                text: resets.map { tr("agents.notice.limitUntil", $0.formatted(date: .omitted, time: .shortened)) }
                                    ?? tr("agents.notice.limit"),
                                detail: resets == nil ? text : nil)
                .padding(.vertical, NookTheme.Spacing.xs)
        case .error(let text):
            TimelineProblemCard(text: text)
                .padding(.vertical, NookTheme.Spacing.xs)
        case nil:
            EmptyView()
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
