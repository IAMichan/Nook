import Foundation

/// One entry of the Summary's conversation: a comment or review on its own, or a thread on a line of the diff with the
/// replies under its first comment.
struct PullRequestConversationItem: Identifiable, Equatable, Sendable {
    let root: PullRequestEvent
    var replies: [PullRequestEvent] = []

    var id: String { root.id }
    /// The root and its replies, oldest first.
    var events: [PullRequestEvent] { [root] + replies }

    var isThread: Bool {
        if case .lineComment = root.kind { return true }
        return false
    }

    /// Done with: a resolved thread or a dismissed review. It shows folded to one line, and the filter can hide it.
    var finished: Bool {
        if root.resolved { return true }
        if case .review("DISMISSED") = root.kind { return true }
        return false
    }
}

/// The Summary's conversation, read as threads: threads on lines keep their replies together, finished
/// ones fold, bots and finished threads can be filtered out, and the most recent ones show first a page at a time.
/// Foundation only, so tests can use it.
enum PullRequestConversation {
    /// How many conversations the Summary shows before "Show older".
    static let page = 10

    /// The comments, reviews that say something or give a verdict, and threads on lines, in the order they started.
    /// A reply whose thread's first comment is not among the events (GitHub's lists were cut short) stands on its own.
    /// Kept per timeline: the page asks for them two or three times on every draw.
    static func items(_ events: [PullRequestEvent]) -> [PullRequestConversationItem] {
        itemsMemo.value(for: events, make: build)
    }

    private static let itemsMemo = RecentMemo<[PullRequestEvent], [PullRequestConversationItem]>(limit: 4)

    private static func build(_ events: [PullRequestEvent]) -> [PullRequestConversationItem] {
        let shown = events.filter(isConversation)
        let roots = Set(shown.filter { $0.replyTo == nil }.map(\.id))
        var replies: [String: [PullRequestEvent]] = [:]
        for event in shown {
            if let root = event.replyTo, roots.contains(root) { replies[root, default: []].append(event) }
        }
        return shown.compactMap { event in
            if let root = event.replyTo, roots.contains(root) { return nil }
            return PullRequestConversationItem(root: event, replies: replies[event.id] ?? [])
        }
    }

    static func isConversation(_ event: PullRequestEvent) -> Bool {
        switch event.kind {
        case .comment, .lineComment: return true
        case .review(let state): return !event.body.isEmpty || state == "APPROVED" || state == "CHANGES_REQUESTED"
        case .commit, .activity: return false
        }
    }

    static func isBot(_ login: String) -> Bool { login.lowercased().hasSuffix("[bot]") }

    /// The items the filter lets through. One member that passes keeps the whole item, so a person's answer to a bot
    /// keeps the bot's comment beside it.
    static func filtered(_ items: [PullRequestConversationItem], bots: Bool, finished: Bool) -> [PullRequestConversationItem] {
        items.filter { item in
            (finished || !item.finished) && item.events.contains { bots || !isBot($0.author) }
        }
    }

    /// How many comments the items hold, replies included.
    static func commentCount(_ items: [PullRequestConversationItem]) -> Int {
        items.reduce(0) { $0 + $1.events.count }
    }

    /// The `count` most recent items, and how many older ones that leaves out.
    static func recent(_ items: [PullRequestConversationItem], count: Int) -> (shown: [PullRequestConversationItem], hidden: Int) {
        let shown = Array(items.suffix(max(0, count)))
        return (shown, items.count - shown.count)
    }

    /// A body as one plain line, for a folded comment: no HTML comments, alert markers, link targets, headings,
    /// quote marks, list bullets, emphasis or code ticks. Kept per body: six regular expressions on every draw of a
    /// folded comment added up.
    static func preview(_ body: String) -> String {
        if let kept = previews.value(for: body) { return kept }
        let text = plainLine(body)
        previews.set(text, for: body)
        return text
    }

    private static let previews = BoundedCache<String, String>(limit: 128)

    private static func plainLine(_ body: String) -> String {
        var text = body
        let rules: [(String, String)] = [
            ("<!--[\\s\\S]*?-->", ""),
            ("(?m)^\\s*>?\\s*\\[!\\w+\\]\\s*$", ""),
            ("!?\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("(?m)^[\\s>#*-]+", ""),
            ("[*`]", ""),
            ("\\s+", " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The last few results of a function of a list, for what a view works out from the same list on every draw. Looking up
/// the same array again is cheap: `==` sees it is the same storage before it compares any element.
final class RecentMemo<Input: Equatable, Output>: @unchecked Sendable {
    private let limit: Int
    private var entries: [(input: Input, output: Output)] = []
    private let lock = NSLock()

    init(limit: Int) { self.limit = max(1, limit) }

    func value(for input: Input, make: (Input) -> Output) -> Output {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.input == input }) {
            let output = entries[index].output
            lock.unlock()
            return output
        }
        lock.unlock()
        let output = make(input)
        lock.lock()
        entries.insert((input, output), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        lock.unlock()
        return output
    }
}
