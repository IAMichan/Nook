import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// What `AgentRunPanel` draws from a session's events: the shown events, their blocks, the turns that changed files, the
/// outputs and the running command. Each walks the whole timeline, and the panel's body runs on every keystroke in its
/// composer (the draft is its state), on hover and while the side panels resize; this makes them again only when the
/// events or the session's tasks, folder or activity change. Comparing the same array again is cheap: Swift sees it is
/// the same storage.
@MainActor
final class RunTimelineDerived {
    private var key: (all: [RunEvent], active: Bool, tasks: [RunTaskStep]?, directory: String, detail: TimelineDetail)?
    private(set) var events: [RunEvent] = []
    private(set) var blocks: [TimelineBlock] = []
    private(set) var turns: [TurnDiff] = []
    /// The answer that ends each finished turn: only it carries the footer (copy and time), as in an agent's own
    /// transcript (`TranscriptPresentation`).
    private(set) var finalAnswers: Set<UUID> = []
    /// Each turn's changed-files card, under the turn's final answer (inside the reply, above its footer); a turn without
    /// an answer keeps it under the line that ends it.
    private(set) var cards: [UUID: TurnDiff] = [:]
    /// The newest final answer while the agent waits: a question at its end can be answered with a click.
    private(set) var answerable: UUID?
    private(set) var outputs: [SessionOutput] = []
    /// `SessionOutputs.signature` of each output: the panel compares them on every redraw, also for every streamed token.
    private(set) var outputSignatures: [String] = []
    /// The subagents since your last message while the agent works or any of them still runs, for the bar above the
    /// composer (which redraws on every keystroke).
    private(set) var subagents: [SubagentInfo] = []
    /// Every subagent of the session, for the Subagents tab of the side panel, and their `Subagents.signature`.
    private(set) var allSubagents: [SubagentInfo] = []
    private(set) var subagentsSignature = ""
    /// The commands it left running in the background since your last message while it works or any still runs, for the
    /// bar above the composer; and all of them, for the Subagents tab (`BackgroundCommands`).
    private(set) var commands: [BackgroundCommandInfo] = []
    private(set) var allCommands: [BackgroundCommandInfo] = []
    /// The last pull request the agent reported with `<pr-created>`, for the tray above the composer.
    private(set) var createdPullRequest: URL?
    /// How far each running command and subagent is, by event id (`WorkProgress`): the live line, the bar above the
    /// composer and the Subagents tab show it.
    private(set) var progress: [UUID: WorkProgress] = [:]

    /// Counts the changes to the events other than more text in the answer being written (`TimelineRowContext`).
    private(set) var revision = 0
    /// Your messages, for the marks on the rail beside the session.
    private(set) var marks: [PromptMark] = []
    /// The blocks of each turn, oldest first: what `HistoryWindow` leaves out when only the latest turns are drawn.
    private(set) var rowsPerTurn: [Int] = []
    /// The turn of each shown event, made when first asked after the turns changed.
    private var turnOfEvent: [UUID: Int]?
    /// The pull request the events before the last one link, so a streamed answer only has to look at itself.
    private var pullRequestBeforeLast: URL?
    /// Each turn's blocks, so only the turn that changed is laid out again.
    private var blockCache = TimelineBlockCache()
    /// Each finished turn's changed files, so only a turn whose events changed is read again.
    private var turnCache = TurnDiffCache()
    /// The last search in the find bar, for the events it searched.
    private var found: (query: String, events: [RunEvent], result: TimelineSearchResult)?

    /// The last one per session: opening a session again takes its blocks, turns and caches as they were, so unchanged
    /// events cost nothing before the first frame and new ones only lay out the turn that changed (as
    /// `TranscriptDerived` keeps them per transcript).
    private static var byRun: [UUID: RunTimelineDerived] = [:]
    private static var order: [UUID] = []
    private static let limit = 16

    /// The derived timeline of this session from its last visit, or a new one.
    static func forRun(_ id: UUID) -> RunTimelineDerived {
        byRun[id] ?? RunTimelineDerived()
    }

    /// Whether it was made from any events yet: a session whose timeline is still being read from disk keeps what it
    /// showed last time instead of being laid out again from nothing.
    var hasContent: Bool { key.map { !$0.all.isEmpty } ?? false }

    /// The find bar's matches, searched again only when the query or the events changed.
    func search(_ query: String) -> TimelineSearchResult {
        if let found, found.query == query, found.events == events { return found.result }
        let result = TimelineSearch.search(events, query: query)
        found = (query, events, result)
        return result
    }

    /// The turn an event is in (by `TimelinePresentation.split` of the shown events), for revealing it in the window.
    func turn(of eventID: UUID) -> Int? {
        if let turnOfEvent { return turnOfEvent[eventID] }
        var made: [UUID: Int] = [:]
        for (index, turn) in blockCache.turns.enumerated() {
            for event in turn.events { made[event.id] = index }
        }
        turnOfEvent = made
        return made[eventID]
    }

    @discardableResult
    func update(_ all: [RunEvent], run: WorkspaceRun, detail: TimelineDetail) -> RunTimelineDerived {
        let active = run.status.isActive
        let sameRun = key.map {
            $0.active == active && $0.directory == run.workingDirectory && $0.tasks == run.tasks && $0.detail == detail
        } ?? false
        if sameRun, let key, key.all == all { return self }
        defer { remember(run.id) }
        // While the agent writes, only the text of its last answer grows, many times a second. The blocks show that text;
        // the turns, outputs, running command and earlier links do not read it, and each walks the whole session (an edit's
        // diff, every tool's input as JSON), so they stay as they are.
        let streamed = sameRun && key.map { Self.onlyStreamed(from: $0.all, to: all) } == true
        key = (all, active, run.tasks, run.workingDirectory, detail)
        // Only what is shown is filtered: the turns, outputs and subagents below still read every event.
        events = detail.filter(all.filter { !($0.kind == .system && $0.tool == "launch") })
        blocks = TimelinePresentation.blocks(events, active: active, cache: &blockCache)
        rowsPerTurn = blockCache.turns.map(\.blocks.count)
        if streamed, let last = all.last {
            createdPullRequest = RunPullRequestLinks.pullRequest(in: last) ?? pullRequestBeforeLast
            return self
        }
        revision &+= 1
        turnOfEvent = nil
        // Also the turns without an edit: git may find files they changed by a command (`countTurns`).
        turns = TurnDiff.collect(events: all, keepEmpty: true, cache: &turnCache)
        finalAnswers = []
        cards = [:]
        let byTurn = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Split as `TurnDiff.collect` does, so a turn and its card share the id of its first event.
        let split = TimelinePresentation.split(all)
        for (index, turn) in split.enumerated() {
            // A turn still at work gets its final answer (and its card) when it is done.
            let finished = index < split.count - 1 || !active
            let answer = finished ? turn.last(where: { $0.kind == .assistant && $0.tool != "plan" && BackgroundWork.notice($0.text).isEmpty }) : nil
            if let answer { finalAnswers.insert(answer.id) }
            guard let first = turn.first, let diff = byTurn[first.id.uuidString] else { continue }
            if let answer {
                cards[answer.id] = diff
            } else if let end = diff.answerID.flatMap(UUID.init(uuidString:)) {
                cards[end] = diff
            }
        }
        answerable = active ? nil : events.last(where: { $0.kind == .assistant }).flatMap { finalAnswers.contains($0.id) ? $0.id : nil }
        outputs = SessionOutputs.collect(all, tasks: run.tasks, directory: run.workingDirectory)
        outputSignatures = outputs.map(SessionOutputs.signature)
        progress = WorkProgress.running(in: all)
        let progress = progress
        func withProgress(_ agent: SubagentInfo) -> SubagentInfo {
            var agent = agent
            agent.progress = progress[agent.id]
            return agent
        }
        func withProgress(_ command: BackgroundCommandInfo) -> BackgroundCommandInfo {
            var command = command
            command.progress = progress[command.id]
            return command
        }
        allSubagents = Subagents.list(all).map(withProgress)
        allCommands = BackgroundCommands.list(all).map(withProgress)
        subagentsSignature = Subagents.signature(allSubagents) + "|" + BackgroundCommands.signature(allCommands)
        let current = Subagents.current(all).map(withProgress)
        subagents = active || current.contains(where: \.isRunning) ? current : []
        let currentCommands = BackgroundCommands.current(all).map(withProgress)
        commands = active || currentCommands.contains(where: \.isRunning) ? currentCommands : []
        marks = TranscriptPresentation.promptMarks(events: events)
        pullRequestBeforeLast = RunPullRequestLinks.last(in: Array(all.dropLast()))
        createdPullRequest = all.last.flatMap(RunPullRequestLinks.pullRequest(in:)) ?? pullRequestBeforeLast
        return self
    }

    private func remember(_ id: UUID) {
        guard hasContent else { return }
        if Self.byRun[id] !== self { Self.byRun[id] = self }
        // While a session streams it stays the newest, so its tokens leave the order alone.
        if Self.order.last != id {
            Self.order.removeAll { $0 == id }
            Self.order.append(id)
            while Self.order.count > Self.limit { Self.byRun[Self.order.removeFirst()] = nil }
        }
    }

    /// Whether `new` is `old` with only more (or other) text in its last answer or thinking: the same events, the last one
    /// the same apart from its text, already written to, and not a plan (whose text is an output) nor turning into a
    /// background notice.
    private static func onlyStreamed(from old: [RunEvent], to new: [RunEvent]) -> Bool {
        guard old.count == new.count, var before = old.last, let after = new.last, before.id == after.id,
              before.kind == .assistant || before.kind == .thinking, before.tool != "plan",
              // The first words make an answer of an empty event: the turns read which event answers.
              !before.text.isEmpty else { return false }
        let wasNotice = BackgroundWork.isNotice(before)
        before.text = after.text
        return before == after && wasNotice == BackgroundWork.isNotice(after) && old.dropLast().elementsEqual(new.dropLast())
    }
}
