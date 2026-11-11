import Foundation

// What a screen reader hears from the session you look at: the step the agent is on, the replies it finishes, and a
// question or approval that waits on you. Built once on the shared timeline shapes (an agent's own transcript,
// `AgentChatMessage`, and a session Nook runs, `RunEvent`), so every agent gets it.
// The view side (`AgentAnnouncer`) only speaks while VoiceOver runs and for the session on screen.

/// How much a screen reader hears from the open session (Settings › Sessions).
enum ScreenReaderAnnouncements: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Nothing beyond what VoiceOver reads by itself.
    case off
    /// The replies the agent finishes, and a question or approval that waits on you.
    case replies
    /// Those, and each step the agent is on ("Editing app.swift").
    case everything

    var id: String { rawValue }
    var titleKey: String { "settings.ws.screenReader." + rawValue }
}

/// What the open session shows now, as far as a screen reader is told.
struct AgentAnnouncementSnapshot: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case working, approval, question, idle
    }

    struct Reply: Equatable, Sendable {
        let id: String
        /// Markdown.
        let text: String
        /// The agent stopped writing it: it went on working after it, or the turn ended.
        let finished: Bool
    }

    var status: Status
    /// The step the agent is on, in words; nil when its newest output is not a step (or it does not work).
    var step: String? = nil
    /// The agent's replies in the latest turn, oldest first.
    var replies: [Reply] = []

    static let idle = AgentAnnouncementSnapshot(status: .idle)
}

/// Decides what is said next, from the snapshot before and the one now.
enum AgentAnnouncements {
    struct Memory: Equatable, Sendable {
        var status: AgentAnnouncementSnapshot.Status
        var step: String?
        /// The replies seen, and whether each was finished then.
        var replies: [String: Bool]
        /// The session was seen working while it was open: only then are its replies new rather than history.
        var sawWork: Bool
    }

    struct Next: Equatable, Sendable {
        var memory: Memory
        /// Said at once, in this order: finished replies, then what waits on you.
        var messages: [String]
        /// The step to say once the reader is quiet; nil when there is no new one.
        var step: String?
    }

    /// Long enough to hear what the agent wrote; the rest is in the conversation.
    static let replyLimit = 600

    /// The first snapshot of a session is a silent baseline: opening a session reads nothing out.
    static func next(_ previous: Memory?, _ snapshot: AgentAnnouncementSnapshot, level: ScreenReaderAnnouncements,
                     author: String) -> Next {
        let working = snapshot.status == .working
        let memory = Memory(status: snapshot.status, step: working ? snapshot.step : nil,
                            replies: Dictionary(snapshot.replies.map { ($0.id, $0.finished) }, uniquingKeysWith: { $1 }),
                            sawWork: (previous?.sawWork ?? false) || snapshot.status != .idle)
        guard let previous, level != .off else { return Next(memory: memory, messages: [], step: nil) }
        var messages: [String] = []
        // A turn that ended before you opened the session is history, however late its transcript arrives.
        if memory.sawWork {
            for reply in snapshot.replies where reply.finished && previous.replies[reply.id] != true {
                let text = spoken(reply.text)
                if !text.isEmpty { messages.append(tr("ws.announce.reply", author, text)) }
            }
        }
        if snapshot.status != previous.status {
            switch snapshot.status {
            case .approval: messages.append(tr("ws.announce.approval", author))
            case .question: messages.append(tr("ws.announce.question", author))
            case .working, .idle: break
            }
        }
        let step = level == .everything && working && memory.step != previous.step ? memory.step : nil
        return Next(memory: memory, messages: messages, step: step)
    }

    /// A reply as it is read: plain words without Markdown, cut short after `replyLimit` characters.
    static func spoken(_ markdown: String) -> String {
        var text = markdown
        // Code blocks are not read out word by word.
        text = text.replacingOccurrences(of: "```[\\s\\S]*?(```|$)", with: " " + tr("ws.announce.code") + " ",
                                         options: .regularExpression)
        // [label](url) reads as its label, an image as nothing.
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        // Headings, quotes and list marks at the start of a line.
        text = text.replacingOccurrences(of: "(?m)^\\s{0,3}(#{1,6}|>|[-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression)
        // Emphasis and inline code marks.
        text = text.replacingOccurrences(of: "[*_`~]+", with: "", options: .regularExpression)
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > replyLimit else { return text }
        return String(text.prefix(replyLimit)).trimmingCharacters(in: .whitespaces) + "… " + tr("ws.announce.more")
    }

    // MARK: Snapshots

    /// An agent's own transcript: `working` and `waiting` as its hooks report them.
    static func snapshot(_ messages: [AgentChatMessage], status: AgentAnnouncementSnapshot.Status,
                         step: String?) -> AgentAnnouncementSnapshot {
        let turn = TranscriptPresentation.split(messages.filter { !($0.isThinking && $0.text.isEmpty) }).last ?? []
        let replies = turn.enumerated().compactMap { offset, message -> AgentAnnouncementSnapshot.Reply? in
            guard message.kind == .assistant, !message.text.isEmpty else { return nil }
            return .init(id: message.id, text: message.text, finished: status == .idle || offset < turn.count - 1)
        }
        return AgentAnnouncementSnapshot(status: status, step: step, replies: replies)
    }

    /// A session Nook runs: its timeline, and whether it works or waits on you.
    static func snapshot(_ events: [RunEvent], status: AgentAnnouncementSnapshot.Status, step: String?) -> AgentAnnouncementSnapshot {
        let turn = TimelinePresentation.lastTurn(events)
        let replies = turn.enumerated().compactMap { offset, event -> AgentAnnouncementSnapshot.Reply? in
            // Nook's note that background work ended is no reply of the agent's.
            guard event.kind == .assistant, !event.text.isEmpty, !BackgroundWork.isNotice(event) else { return nil }
            return .init(id: event.id.uuidString, text: event.text, finished: status == .idle || offset < turn.count - 1)
        }
        return AgentAnnouncementSnapshot(status: status, step: step, replies: replies)
    }
}

/// Spaces out what is said: a reply or a request is said at once, and a step waits until the reader
/// had time for what came before it; a newer step takes the place of one still waiting, so a quick step can be skipped.
/// Nothing repeats: at most one step waits, on a single timer.
@MainActor
final class AnnouncementPacer {
    /// Long enough for a screen reader to finish a short label before the next one.
    nonisolated static let gap: TimeInterval = 2
    /// A reply is read at about this pace; a step after it waits that long, at most `holdLimit`.
    nonisolated static let perCharacter: TimeInterval = 0.05
    nonisolated static let holdLimit: TimeInterval = 15

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let speak: (String) -> Void
    private var quietUntil = Date.distantPast
    private var waiting: (label: String, cancel: () -> Void)?

    /// `schedule` runs its closure once after the delay and returns a way to cancel it.
    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = AnnouncementPacer.dispatch,
         speak: @escaping (String) -> Void) {
        self.now = now
        self.schedule = schedule
        self.speak = speak
    }

    /// How long a step waits after `text` was said.
    nonisolated static func hold(after text: String) -> TimeInterval {
        min(holdLimit, max(gap, Double(text.count) * perCharacter))
    }

    /// One announcement, since one said right after another cuts it off: each part ends as a sentence.
    nonisolated static func joined(_ texts: [String]) -> String {
        texts.enumerated().map { offset, text in
            offset == texts.count - 1 || text.last.map { ".!?:…".contains($0) } == true ? text : text + "."
        }.joined(separator: " ")
    }

    /// Says these at once; a step waits until they had time to be heard.
    func say(_ texts: [String]) {
        guard !texts.isEmpty else { return }
        let text = Self.joined(texts)
        speak(text)
        quietUntil = max(quietUntil, now().addingTimeInterval(Self.hold(after: text)))
    }

    /// The step the agent is on now: said when the reader is quiet, else once it is (unless a newer one comes first).
    /// Nil drops a step that still waits (the agent moved on to something that is no step, or stopped).
    func step(_ label: String?) {
        waiting?.cancel()
        waiting = nil
        guard let label else { return }
        let wait = quietUntil.timeIntervalSince(now())
        if wait <= 0 {
            sayStep(label)
            return
        }
        let cancel = schedule(wait) { [weak self] in
            guard let self, self.waiting?.label == label else { return }
            self.waiting = nil
            self.sayStep(label)
        }
        waiting = (label, cancel)
    }

    /// Forgets what waits, for another session or when the session leaves the screen.
    func reset() {
        waiting?.cancel()
        waiting = nil
        quietUntil = .distantPast
    }

    /// A step still waits to be said.
    var hasWaitingStep: Bool { waiting != nil }

    private func sayStep(_ label: String) {
        speak(label)
        quietUntil = now().addingTimeInterval(Self.gap)
    }

    nonisolated static func dispatch(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
