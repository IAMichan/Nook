import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// What `AgentRunPanel` draws from a session's events: the shown events, their blocks, the turns that changed files, the
/// outputs and the running command. Each walks the whole timeline, and the panel's body runs on hover, resize and
/// unrelated updates; this makes them again only when the timeline's version or the session's tasks, folder or activity
/// change. Keying on monotonic version counters (`WorkspaceManager.timelineVersion`) avoids both O(N) `Array.==` scans
/// and retaining a copy of `[RunEvent]` (which would defeat copy-on-write on `WorkspaceManager.events` during streaming).
@MainActor
final class RunTimelineDerived {
    private var key: (version: UInt64, structureVersion: UInt64, count: Int, active: Bool, tasks: [RunTaskStep]?, directory: String, detail: TimelineDetail)?
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
    /// Reads only the events that may hold a newer link (`RunPullRequestLinks.Scan`), not the whole session per event.
    private var pullRequestScan = RunPullRequestLinks.Scan()
    /// Each turn's blocks, so only the turn that changed is laid out again.
    private var blockCache = TimelineBlockCache()
    /// Each finished turn's changed files, so only a turn whose events changed is read again.
    private var turnCache = TurnDiffCache()
    /// The turns with what git counted for them (`countedTurns`), made again only when the turns, the counts or the
    /// folder changed.
    private var counted: (revision: Int, lines: [String: TurnLines], directory: String?,
                          all: [TurnDiff], byID: [String: TurnDiff])?
    /// The last search in the find bar, keyed by query + timeline version + detail filter.
    private var found: (query: String, version: UInt64, detail: TimelineDetail?, result: TimelineSearchResult)?

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
    var hasContent: Bool { key.map { $0.count > 0 } ?? false }

    /// The find bar's matches, searched again only when the query or the events changed.
    func search(_ query: String) -> TimelineSearchResult {
        let version = key?.version ?? 0
        let detail = key?.detail
        if let found, found.query == query, found.version == version, found.detail == detail { return found.result }
        let result = TimelineSearch.search(events, query: query)
        found = (query, version, detail, result)
        return result
    }

    /// The finished turns with the lines git counted (`lines`, by turn id) in place of those read from the agent's edits:
    /// every turn (`all`, the empty ones left out) and by id, for the cards. The panel asks on every redraw, for the
    /// outputs tab and for each card it draws; counting a long session's turns again each time (every file's path made
    /// relative, for every turn) was a steady cost of scrolling and hovering.
    func countedTurns(_ lines: [String: TurnLines], directory: String?) -> (all: [TurnDiff], byID: [String: TurnDiff]) {
        if let counted, counted.revision == revision, counted.directory == directory, counted.lines == lines {
            return (counted.all, counted.byID)
        }
        var byID: [String: TurnDiff] = [:]
        for turn in turns {
            byID[turn.id] = lines[turn.id].map { turn.counted($0, relativeTo: directory) } ?? turn
        }
        let all = turns.compactMap { byID[$0.id] }.filter { !$0.isEmpty }
        counted = (revision, lines, directory, all, byID)
        return (all, byID)
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
    func update(_ all: [RunEvent], version: UInt64, structureVersion: UInt64,
                run: WorkspaceRun, detail: TimelineDetail) -> RunTimelineDerived {
        let active = run.status.isActive
        let sameRun = key.map {
            $0.active == active && $0.directory == run.workingDirectory && $0.tasks == run.tasks && $0.detail == detail
        } ?? false
        if sameRun, let key, key.version == version, key.count == all.count { return self }
        defer { remember(run.id) }
        // While the agent writes or streams command output, `structureVersion` stays unchanged so we know in O(1) that
        // only the last event grew. Turns, outputs, subagents, commands and earlier PR links do not change.
        let streamed = sameRun && key.map { $0.structureVersion == structureVersion && $0.count == all.count && $0.count > 0 } == true
        key = (version, structureVersion, all.count, active, run.tasks, run.workingDirectory, detail)
        if streamed, let last = all.last {
            if events.last?.id == last.id {
                events[events.count - 1] = last
                if !TimelinePresentation.updateLastEvent(last, active: active, cache: &blockCache,
                                                         blocks: &blocks, rowsPerTurn: &rowsPerTurn) {
                    blocks = TimelinePresentation.blocks(events, active: active, cache: &blockCache)
                    rowsPerTurn = blockCache.turns.map(\.blocks.count)
                }
            }
            if last.kind == .tool {
                let reported = WorkProgress.reported(in: last.output)
                let expected = progress[last.id]?.expected
                progress[last.id] = (reported != nil || expected != nil)
                    ? WorkProgress(reported: reported, started: last.date, expected: expected) : nil
            }
            createdPullRequest = RunPullRequestLinks.pullRequest(in: last) ?? pullRequestBeforeLast
            return self
        }
        // Only what is shown is filtered: the turns, outputs and subagents below still read every event.
        events = detail.filter(all.filter { !($0.kind == .system && $0.tool == "launch") })
        blocks = TimelinePresentation.blocks(events, active: active, cache: &blockCache)
        rowsPerTurn = blockCache.turns.map(\.blocks.count)
        revision &+= 1
        turnOfEvent = nil
        // Also the turns without an edit: git may find files they changed by a command (`countTurns`).
        turns = TurnDiff.collect(events: all, keepEmpty: true, cache: &turnCache)
        finalAnswers = []
        cards = [:]
        let byTurn = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func answer(of turn: [RunEvent]) -> RunEvent? {
            turn.last(where: { $0.kind == .assistant && $0.tool != "plan" && BackgroundWork.notice($0.text).isEmpty })
        }
        let split = TimelinePresentation.split(all)
        for (index, turn) in split.enumerated() where index < split.count - 1 || !active {
            // A turn still at work gets its final answer when it is done.
            if let answer = answer(of: turn) { finalAnswers.insert(answer.id) }
        }
        // Split as `TurnDiff.collect` does (`TurnDiff.workTurns`), so a turn and its card share the id of its first event:
        // a turn and the wake turns that finished its background work share one,
        // under the last answer of them all.
        let work = TurnDiff.workTurns(all)
        for (index, turn) in work.enumerated() {
            let finished = index < work.count - 1 || !active
            let answer = finished ? answer(of: turn) : nil
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
        // Taken from the lists above, not by reading the session again.
        subagentsSignature = Subagents.signature(allSubagents) + "|" + BackgroundCommands.signature(allCommands)
        let current = Subagents.current(all, listed: allSubagents)
        subagents = active || current.contains(where: \.isRunning) ? current : []
        let currentCommands = BackgroundCommands.current(all, listed: allCommands)
        commands = active || currentCommands.contains(where: \.isRunning) ? currentCommands : []
        marks = TranscriptPresentation.promptMarks(events: events)
        pullRequestBeforeLast = pullRequestScan.last(in: all, upTo: all.count - 1)
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
}
