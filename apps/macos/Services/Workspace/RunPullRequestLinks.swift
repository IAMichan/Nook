import Foundation

/// The last pull request a run's conversation links, for the tray above its composer and the badge on its row. Kept per
/// run and read again only when the conversation changed, as every row of the list asks on each redraw.
@MainActor
final class RunPullRequestLinks {
    static let shared = RunPullRequestLinks()
    private var memo: [UUID: (count: Int, last: UUID?, url: URL?)] = [:]

    func url(_ id: UUID, events: [RunEvent]) -> URL? {
        if let hit = memo[id], hit.count == events.count, hit.last == events.last?.id { return hit.url }
        let url: URL?
        if let hit = memo[id], hit.count > 0, hit.count < events.count, events[hit.count - 1].id == hit.last {
            // Events came after the ones read: only those (and the last one read, which may have grown while it streamed)
            // can hold a newer link. Reading the whole session again on every event of a long run cost the inbox list
            // a scan of thousands of events per update.
            url = Self.last(in: events[(hit.count - 1)...]) ?? hit.url
        } else {
            url = Self.last(in: events)
        }
        memo[id] = (events.count, events.last?.id, url)
        return url
    }

    /// The last link of the conversation before a session's current turn, as the end of an earlier turn read it: the
    /// events up to `count`, the last of them `lastID`.
    struct BeforeTurn: Equatable {
        var count: Int
        var lastID: UUID
        var url: URL?
    }

    /// At the end of a turn: the pull request link the turn brought (from the last `.user` event on) that the conversation
    /// did not have before it; nil when there is none. `before` remembers the link before the turn, so the next turn reads
    /// only the events that came after it instead of the whole conversation again on every `.result`.
    nonisolated static func created(in events: [RunEvent], before memo: inout BeforeTurn?) -> URL? {
        guard let start = events.lastIndex(where: { $0.kind == .user }),
              let made = last(in: events[start...]) else { return nil }
        let earlier: URL?
        if let hit = memo, hit.count > 0, hit.count <= start, events[hit.count - 1].id == hit.lastID {
            // The last event read may have grown since (a tool's output came in later): it is read again.
            earlier = last(in: events[(hit.count - 1)..<start]) ?? hit.url
        } else {
            earlier = last(in: events[..<start])
        }
        memo = start > 0 ? BeforeTurn(count: start, lastID: events[start - 1].id, url: earlier) : nil
        return made == earlier ? nil : made
    }

    nonisolated static func last(in events: [RunEvent]) -> URL? {
        last(in: events[...])
    }

    /// The last link of a growing conversation's first events, read again only from where they may have changed since
    /// the last call: the oldest recent call that still ran, else the last event read (it may have grown). Reading every
    /// event again on each new one cost a long session (thousands of calls, megabytes of output) a fifth of a second of
    /// the main thread per tool call. Events taken away or replaced (going back to before a message) read all again.
    struct Scan: Sendable {
        /// How far back a call that still runs keeps its place to be read again: a command left running in the background
        /// for hours would otherwise bring back a read of nearly the whole session on every event.
        static let runningReach = 256

        private var count = 0
        private var lastID: UUID?
        /// The first event to read again, and the last link of the events before it.
        private var resume = 0
        private var settled: URL?

        init() {}

        /// The last link in `events[..<end]`.
        mutating func last(in events: [RunEvent], upTo end: Int) -> URL? {
            let end = min(max(end, 0), events.count)
            let valid = count > 0 && count <= end && events[count - 1].id == lastID && resume < count
            let start = valid ? resume : 0
            if !valid { settled = nil }
            let reach = max(start, end - Self.runningReach)
            let nextResume = (reach..<end).first { events[$0].state == .running } ?? max(start, end - 1)
            var newest = settled
            var nextSettled = settled
            for index in start..<end {
                guard let url = RunPullRequestLinks.pullRequest(in: events[index]) else { continue }
                newest = url
                if index < nextResume { nextSettled = url }
            }
            count = end
            lastID = end > 0 ? events[end - 1].id : nil
            resume = nextResume
            settled = nextSettled
            return newest
        }
    }

    nonisolated static func last(in events: ArraySlice<RunEvent>) -> URL? {
        events.reversed().lazy.compactMap(pullRequest(in:)).first
    }

    /// The last pull request link an event carries: the agent's words, or what a tool that made or showed one printed
    /// (`gh pr create` prints its link, and the agent does not always repeat it).
    nonisolated static func pullRequest(in event: RunEvent) -> URL? {
        switch event.kind {
        case .assistant:
            return MarkdownBlock.lastGitHubPullRequest(in: event.text)
        case .tool:
            // A byte search of the output first (it rules out almost every call; `String.contains` walked megabytes of
            // output character by character), then whether the call can show a
            // pull request at all, and only then the output's links: an agent that searches code full of pull request
            // links (a project's own tests) printed megabytes of "/pull/", and reading each output with the link pattern
            // was most of what a long session cost to open.
            guard let output = event.output, SearchText.contains(output, "/pull/"),
                  PullRequestToolCall.showsPullRequest(tool: event.tool, command: [event.text, event.detail]) else { return nil }
            return MarkdownBlock.lastGitHubPullRequest(in: output)
        default:
            return nil
        }
    }

    /// The same for a conversation Nook reads from an agent's transcript (a session it only sees).
    nonisolated static func last(in messages: [AgentChatMessage]) -> URL? {
        for message in messages.reversed() {
            switch message.kind {
            case .assistant:
                if let url = MarkdownBlock.lastGitHubPullRequest(in: message.text) { return url }
            case .tools:
                for step in message.steps.reversed() {
                    guard let output = step.output, let url = MarkdownBlock.lastGitHubPullRequest(in: output),
                          PullRequestToolCall.showsPullRequest(tool: step.name, command: [step.summary, step.command]) else { continue }
                    return url
                }
            default:
                continue
            }
        }
        return nil
    }
}
