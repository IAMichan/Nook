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
    /// Read only by the handlers: as state, each start and stop of a scroll drew every row of the conversation again.
    @State private var scrollPhase = Unobserved(ScrollPhase.idle)
    /// The rows on screen, for where you left the conversation; not state, so scrolling does not redraw it.
    @State private var onScreen = VisibleTimelineRows()
    /// Where the conversation is scrolled, for the rail, and the position the rail scrolls it to when you drag it.
    @State private var viewport = TimelineViewport()
    @State private var position = ScrollPosition()
    /// Where you left this conversation last time (TimelineVisitStore), read as it opens.
    @State private var visit: TimelineVisit?
    /// The row the "New since your last visit" line sits above; decided once the conversation has loaded.
    @State private var newSince: String?
    /// The transcript was read fresh for this view (not only taken from the cache): what is new since shows then.
    @State private var freshRead = false
    @State private var derived = TranscriptDerived()

    /// The conversation as read from the transcript; before this view's first read, as it was read last time, so a
    /// conversation you switch back to shows from the first frame instead of after the read is under way.
    private var transcriptMessages: [AgentChatMessage] {
        messages.isEmpty && readPath != path ? TranscriptCache.messages(path) ?? [] : messages
    }

    private var shown: [AgentChatMessage] {
        let read = transcriptMessages
        return read.isEmpty ? fallback : read
    }

    /// The session's key in TimelineVisitStore: its transcript; nil for a conversation read from elsewhere.
    private var visitKey: String? { path.isEmpty ? nil : "transcript:" + path }

    private var visitRows: [TimelineLanding.Row] {
        derived.rows.map { ($0.id, $0.visitDate) }
    }

    var body: some View {
        // Only a conversation read from the transcript is kept for the next visit, not the fallback shown before it.
        let _ = derived.update(shown, working: working, directory: directory, path: transcriptMessages.isEmpty ? "" : path)
        let rows = derived.rows
        let outputs = derived.outputs
        let turns = derived.turns
        let beforeNew = newSince.flatMap { id in rows.firstIndex { $0.id == id } }.flatMap { $0 > 0 ? rows[$0 - 1].id : nil }
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                // No scroll bar, not even when the system shows them always: the rail beside it marks your messages and scrolls.
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
                                    self.row(row)
                                }
                                .id(row.id)
                            } else {
                                // The "new since" line is a hairline of its own: a fold right above it gives up its own.
                                self.row(row, ruled: row.id != beforeNew).id(row.id)
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
                .scrollPosition($position)
                // Open at the newest message; the transcript loads after the view appears, so also follow it once it arrives.
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                // Only while following does growth keep the end in place: reading higher up, a working agent's new
                // output below leaves the text you read where it is instead of pushing it up.
                .defaultScrollAnchor(scroll.shouldFollowEnd ? .bottom : nil, for: .sizeChanges)
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.1) { ids in onScreen.ids = Set(ids) }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: ScrollFrame.self) { geometry in
                    ScrollFrame(offset: geometry.contentOffset.y, content: geometry.contentSize.height,
                                container: geometry.containerSize.height,
                                insetTop: geometry.contentInsets.top, insetBottom: geometry.contentInsets.bottom)
                } action: { _, frame in
                    viewport.frame = frame
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
                } action: { _, nowAtEnd in
                    atEnd = nowAtEnd
                    if nowAtEnd { scroll.reachedEnd() }
                }
                // While following, growth keeps the distance to the end, so getting further from it can only be you:
                // this catches a mouse wheel too, which reports no scroll phase.
                .onScrollGeometryChange(for: [Double].self) { geometry in
                    [geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height,
                     geometry.containerSize.height]
                } action: { old, new in
                    if scroll.shouldFollowEnd, new[0] > old[0] + 0.5, new[0] > 48, new[1] == old[1] { scroll.userScrolled() }
                }
                .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height > $0.containerSize.height + 1 } action: { _, now in
                    overflows = now
                }
                .overlay(alignment: .trailing) {
                    if overflows, !derived.marks.isEmpty {
                        TranscriptPromptRail(marks: derived.marks, viewport: viewport) { mark in
                            scroll.userScrolled()
                            withAnimation(NookTheme.scroll) { proxy.scrollTo(mark.row, anchor: .top) }
                        } onScrub: { offset in
                            if !scroll.isFreeAfterUserScroll { scroll.userScrolled() }
                            position.scrollTo(y: offset)
                        }
                        .padding(.vertical, NookTheme.Spacing.md)
                        .transition(.opacity)
                    }
                }
                .onScrollPhaseChange { _, phase in
                    scrollPhase.value = phase
                    if (phase == .interacting || phase == .decelerating) && !atEnd { scroll.userScrolled() }
                }
                // A drag that began at the end, or the scroll wheel, leaves the end while you scroll: stop following.
                .onChange(of: atEnd) { _, now in
                    if !now, scrollPhase.value != .idle && scrollPhase.value != .animating { scroll.userScrolled() }
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
        .preference(key: SessionOutputsReport.self, value: SessionOutputsReport(outputs: outputs, turns: turns, pullRequest: derived.pullRequest))
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

    /// One row, drawn again only when what it shows changed: the conversation's body runs on every read of a working
    /// agent and on every keystroke in the composer under it, and most rows stay the same.
    private func row(_ row: TranscriptRow, ruled: Bool = true) -> some View {
        TranscriptRowView(row: row, answers: row.id == derived.answerable, cards: derived.rowCards[row.id] ?? [:],
                          checks: derived.foldChecks[row.id] ?? [], open: open, ruled: ruled, directory: directory,
                          side: sideLink, live: row.id == "live" ? shown : [], onReply: onReply,
                          toggle: { toggle($0) })
            .equatable()
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

/// One row of `TranscriptConversation`, keyed on what it shows: its row, whether its answer can be answered, the cards
/// and checks under it, what is open, and the file the side panel shows. The closures are compared by presence only.
private struct TranscriptRowView: View, Equatable {
    let row: TranscriptRow
    /// The last answer, whose options can be tapped to reply.
    let answers: Bool
    /// The changed-files cards under the answers in this row, by answer id.
    let cards: [String: TurnDiff]
    /// The tests and builds a fold holds.
    let checks: [VerificationCheck]
    let open: Set<String>
    let ruled: Bool
    let directory: String?
    let side: SessionSideLink
    /// The whole conversation, for the live line only (what the agent does now and its task list); empty for other rows.
    let live: [AgentChatMessage]
    let onReply: ((String) -> Void)?
    let toggle: (String) -> Void

    static func == (lhs: TranscriptRowView, rhs: TranscriptRowView) -> Bool {
        lhs.row == rhs.row && lhs.answers == rhs.answers && lhs.ruled == rhs.ruled && lhs.directory == rhs.directory
            && lhs.side.shownFile == rhs.side.shownFile && (lhs.onReply == nil) == (rhs.onReply == nil)
            && lhs.open == rhs.open && lhs.cards == rhs.cards && lhs.checks == rhs.checks && lhs.live == rhs.live
    }

    var body: some View {
        if case let (key, text, inner)? = Self.fold(row) {
            TranscriptFold(text: text, open: open.contains(key), checks: checks, ruled: ruled, toggle: { toggle(key) }) {
                ForEach(inner) { flatRow($0, answers: false).id($0.id) }
            }
        } else {
            flatRow(row, answers: answers)
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
    private func flatRow(_ row: TranscriptRow, answers: Bool) -> some View {
        switch row {
        case .user(let message):
            // Space above your message: each turn starts as its own block, as in the Nook chat.
            TranscriptUserMessage(text: message.text, date: message.date, steered: message.queued)
                .padding(.top, TranscriptStyle.turnGap - NookTheme.Spacing.sm)
                .padding(.bottom, NookTheme.Spacing.xxs)
        case .assistant(let message, let isFinal):
            // Only the final answer of a turn has the footer (copy and time).
            TranscriptReply(text: message.text, date: message.updated ?? message.date, footer: isFinal,
                            onChoose: answers ? onReply : nil) {
                // What the turn changed, under its answer: a click opens the diff beside the conversation.
                if let turn = cards[message.id] {
                    TurnChangesCard(turn: turn, directory: directory) { file in
                        side.openDiff(TurnDiffSelection(turn: turn.id, file: file))
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
                ?? (thought == nil ? TranscriptPresentation.activity(live) : .thinking(""))
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                if let thought { thinking(thought) }
                TranscriptLiveLine(activity: activity, tasks: TranscriptPresentation.tasks(live), help: step.map(Self.label))
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
                               open: opens ? open.contains(key) : nil, reveals: file.map { $0 == side.shownFile }, quietChevron: true) {
                if let file { side.showFile(file) } else { toggle(key) }
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
    /// The last pull request the conversation links (`gh pr create` printed it, or the agent wrote it).
    private(set) var pullRequest: URL?
    /// The tests and builds each fold holds, by the fold's row id: reading every command again on each redraw of the
    /// timeline cost more than the rest of the row.
    private(set) var foldChecks: [String: [VerificationCheck]] = [:]
    /// The last answer while the agent waits: only it can still be answered by tapping one of its options.
    private(set) var answerable: String?
    /// The changed-files cards under the answers each row holds, by the row's id (a fold's by the fold's).
    private(set) var rowCards: [String: [String: TurnDiff]] = [:]

    /// The last one per transcript: switching back to a conversation takes its rows as they were instead of laying the
    /// whole thread out again before the first frame.
    private static var byPath: [String: TranscriptDerived] = [:]
    private static var order: [String] = []
    private static let limit = 12

    func update(_ messages: [AgentChatMessage], working: Bool, directory: String?, path: String) {
        if key == nil, !path.isEmpty, let known = Self.byPath[path], let knownKey = known.key {
            key = knownKey
            rows = known.rows
            outputs = known.outputs
            turns = known.turns
            marks = known.marks
            pullRequest = known.pullRequest
            foldChecks = known.foldChecks
            answerable = known.answerable
            rowCards = known.rowCards
        }
        if let key, key.working == working, key.directory == directory, key.messages == messages { return }
        defer { remember(path) }
        key = (messages, working, directory)
        rows = TranscriptPresentation.rows(messages, working: working)
        outputs = SessionOutputs.collect(messages, directory: directory ?? "").filter { directory != nil || !$0.isFile }
        turns = TurnDiff.collect(messages)
        marks = TranscriptPresentation.promptMarks(rows)
        pullRequest = RunPullRequestLinks.last(in: messages)
        foldChecks = [:]
        for row in rows {
            switch row {
            case .fold(_, _, let inner), .continued(_, _, let inner):
                foldChecks[row.id] = Verification.latest(TranscriptPresentation.steps(inner).compactMap(Verification.check))
            default: break
            }
        }
        answerable = working ? nil : messages.last(where: { $0.kind == .assistant })?.id
        // A turn still at work gets its card when it is done (a message you sent while it worked is part of that turn).
        let lastPrompt = messages.last(where: { $0.kind == .user && !$0.queued })?.id
        let cards = Dictionary(turns.filter { !(working && $0.id == lastPrompt) }.compactMap { turn in turn.answerID.map { ($0, turn) } },
                               uniquingKeysWith: { first, _ in first })
        rowCards = [:]
        for row in rows {
            let answers: [TranscriptRow]
            switch row {
            case .fold(_, _, let inner), .continued(_, _, let inner): answers = inner
            default: answers = [row]
            }
            for case let .assistant(message, _) in answers {
                if let card = cards[message.id] { rowCards[row.id, default: [:]][message.id] = card }
            }
        }
    }

    private func remember(_ path: String) {
        guard !path.isEmpty, !rows.isEmpty else { return }
        Self.byPath[path] = self
        Self.order.removeAll { $0 == path }
        Self.order.append(path)
        while Self.order.count > Self.limit { Self.byPath[Self.order.removeFirst()] = nil }
    }
}

/// Where the conversation is scrolled, for the rail beside it. Kept out of the timeline's own state: it changes on
/// every scroll, and only the rail draws from it.
@Observable
@MainActor
final class TimelineViewport {
    var frame = ScrollFrame()
}

/// Your messages as short marks along the edge of the conversation, where a scroll bar would be: each sits about where
/// the message is, a click scrolls to it, and hovering shows the prompt you wrote. The rail is the scroll bar too: the
/// part in view shows as a thumb, and pressing or dragging anywhere on it scrolls the whole conversation along. The rail
/// itself only shows while the pointer is over it or you drag it.
struct TranscriptPromptRail: View {
    let marks: [PromptMark]
    let viewport: TimelineViewport
    let onSelect: (PromptMark) -> Void
    /// A place on the rail was pressed or dragged to: the offset to scroll the conversation to.
    let onScrub: (Double) -> Void
    @State private var hovered: String?
    /// The pointer is over the rail: only then it shows, with a background so the marks stand out over the text.
    @State private var overRail = false
    @GestureState private var dragging = false
    /// Where the conversation stood when the drag began: the drag maps onto its height then
    /// (`ScrollFrame.offset(at:over:)`), so the conversation follows the pointer smoothly.
    @State private var dragStart: ScrollFrame?

    private static let width: CGFloat = 28
    /// The height each mark can be clicked over.
    private static let target: CGFloat = 16

    private var shown: Bool { overRail || dragging }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.height - Self.target)
            ZStack(alignment: .topLeading) {
                // A fully transparent view is not hit-tested, so this layer keeps the hidden rail hoverable.
                Color.clear.contentShape(Rectangle())
                Group {
                    thumb(travel: travel)
                    marksLayer(travel: travel)
                }
                .opacity(shown ? 1 : 0)
            }
            .frame(width: Self.width, height: geometry.size.height)
            // Alongside the marks' own clicks, so a drag that starts on a mark scrolls as well.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { drag in
                        guard travel > 0 else { return }
                        let start = dragStart ?? viewport.frame
                        if dragStart == nil { dragStart = start }
                        onScrub(viewport.frame.offset(at: Double((drag.location.y - Self.target / 2) / travel), over: start))
                    }
            )
        }
        .frame(width: Self.width)
        // Also when the drag is cancelled, which calls no `onEnded`.
        .onChange(of: dragging) { _, now in
            if !now { dragStart = nil }
        }
        .background(
            RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(DropdownStyle.panel)
                .opacity(shown ? 0.92 : 0)
        )
        .onHover { overRail = $0 }
        .animation(NookTheme.hover, value: hovered)
        .animation(NookTheme.hover, value: shown)
    }

    /// The part of the conversation in view, behind the marks.
    private func thumb(travel: CGFloat) -> some View {
        let part = (dragStart.map { viewport.frame.measured(over: $0) } ?? viewport.frame).thumb
        let height = max(Self.target, CGFloat(part.length) * travel)
        let top = min(Self.target / 2 + CGFloat(part.start) * travel, Self.target / 2 + travel - height)
        return RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
            .fill(NookTheme.textTertiary.opacity(dragging ? 0.32 : 0.18))
            .frame(width: Self.width - NookTheme.Spacing.sm * 2, height: height)
            .offset(x: NookTheme.Spacing.sm, y: max(0, top))
            .allowsHitTesting(false)
    }

    private func marksLayer(travel: CGFloat) -> some View {
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

/// A value a view keeps across redraws that it only reads in its handlers (where a scroll is, whether you drag it).
/// Held in `@State`, writing it draws nothing again: written on every scroll, plain state redrew the whole view.
final class Unobserved<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
