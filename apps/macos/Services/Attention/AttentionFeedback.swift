import Foundation

/// What you did with something Nook told you or offered: the signal Nook learns from, the same for every source
/// (agents, chats, Nook himself, Think Along, the moments).
enum AttentionEvent: String, Codable, CaseIterable, Sendable {
    /// It popped up (a card, a line, a banner).
    case shown
    /// You opened it or went to what it is about.
    case opened
    /// You closed it or said no ("Not now", "OK" without acting).
    case dismissed
    /// It went away by itself without you touching it.
    case timedOut
    /// You put it off until later.
    case snoozed
    /// You asked never to hear about it again here (a chat set to quiet, an app muted for Think Along).
    case muted
    /// You answered it (a reply, an accepted offer, an answer to a question).
    case answered
    /// You allowed what it asked.
    case approved
    /// You declined what it asked: still a decision you were glad to be asked for.
    case denied

    /// Points for engagement, and against it, at full weight. Approving or denying both mean the notice was worth it.
    var weights: (positive: Double, negative: Double) {
        switch self {
        case .shown: return (0, 0)
        case .opened, .answered, .approved, .denied: return (1, 0)
        case .dismissed: return (0, 1)
        case .timedOut, .snoozed: return (0, 0.5)
        case .muted: return (0, 3)
        }
    }
}

/// Learns from what you do with Nook's notices, per source, app and subject ("chats" · "whatsapp" · a chat; "suggestions"
/// · a bundle id · a topic): what you keep dismissing waits longer before it pops up again (`gapFactor`) and ranks lower
/// (`weight`), what you act on keeps its place. Evidence fades over two weeks, so a habit that changed is followed.
/// Pure and `Codable`: `AttentionFeedbackStore` keeps it between launches. Tested in AttentionFeedbackTests.
struct AttentionFeedback: Codable, Equatable, Sendable {
    /// Two weeks: what you did a month ago counts a quarter.
    static let halfLife: TimeInterval = 14 * 24 * 3600
    /// A dismissal weighs as much as an action.
    static let negativeWeight: Double = 1
    /// How much longer the pacer waits at most for a source and app you keep turning away.
    static let maxGapFactor: Double = 3

    private(set) var counter = DecayedCounter<String>(halfLife: AttentionFeedback.halfLife,
                                                      negativeWeight: AttentionFeedback.negativeWeight, limit: 400)
    /// How often each source and app popped up, fading the same way: an app that pops up a lot and is never opened learns
    /// faster than one shown once.
    private(set) var exposure = DecayedCounter<String>(halfLife: AttentionFeedback.halfLife, limit: 200)

    init() {}

    /// The key of a source and app, with or without a subject. Lowercased, so "WhatsApp" and "whatsapp" are one.
    static func key(_ source: String, app: String, subject: String? = nil) -> String {
        let base = source.lowercased() + "|" + app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let subject, !subject.isEmpty else { return base }
        return base + "|" + subject
    }

    /// Notes what you did. It counts for the source and app, and for the subject when there is one.
    mutating func record(_ event: AttentionEvent, source: String, app: String = "", subject: String? = nil, at now: Date = Date()) {
        let base = Self.key(source, app: app)
        if event == .shown {
            exposure.add(base, positive: 1, at: now)
            return
        }
        let weights = event.weights
        counter.add(base, positive: weights.positive, negative: weights.negative, at: now)
        if let subject, !subject.isEmpty {
            counter.add(Self.key(source, app: app, subject: subject), positive: weights.positive, negative: weights.negative, at: now)
        }
    }

    /// How welcome notices from here are, -1…1: below zero you mostly turn them away, above zero you mostly act on them,
    /// zero when Nook knows too little. The subject's own evidence counts on top of its app's when there is one.
    func weight(source: String, app: String = "", subject: String? = nil, at now: Date = Date()) -> Double {
        var keys = [Self.key(source, app: app)]
        if let subject, !subject.isEmpty { keys.append(Self.key(source, app: app, subject: subject)) }
        var positive = 0.0, negative = 0.0
        for key in keys {
            let points = counter.points(key, at: now)
            positive += points.positive
            negative += points.negative * Self.negativeWeight
        }
        // Two points of doubt on each side: one dismissal says little, five say a lot.
        return (positive - negative) / (positive + negative + 2)
    }

    /// How much longer the pacer keeps its distance for notices from here: 1 for the usual gap, up to `maxGapFactor` for
    /// a source and app you mostly turn away. Never shorter than usual: acting on notices does not make Nook louder.
    func gapFactor(source: String, app: String = "", at now: Date = Date()) -> Double {
        let weight = weight(source: source, app: app, at: now)
        guard weight < -0.25 else { return 1 }
        return min(Self.maxGapFactor, 1 + (-weight - 0.25) / 0.75 * (Self.maxGapFactor - 1))
    }

    /// How often notices from here popped up lately (faded).
    func shown(source: String, app: String = "", at now: Date = Date()) -> Double {
        exposure.points(Self.key(source, app: app), at: now).positive
    }
}

/// Keeps `AttentionFeedback` in the user defaults. A write happens only when you do something (a click on a card), never
/// on a timer, so idle Nook writes nothing.
final class AttentionFeedbackStore: @unchecked Sendable {
    static let shared = AttentionFeedbackStore()

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var cached: AttentionFeedback

    init(defaults: UserDefaults = .standard, key: String = "attention.feedback.v1") {
        self.defaults = defaults
        self.key = key
        cached = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AttentionFeedback.self, from: $0) } ?? AttentionFeedback()
    }

    var feedback: AttentionFeedback {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    func record(_ event: AttentionEvent, source: String, app: String = "", subject: String? = nil, at now: Date = Date()) {
        lock.lock()
        cached.record(event, source: source, app: app, subject: subject, at: now)
        let data = try? JSONEncoder().encode(cached)
        lock.unlock()
        if let data { defaults.set(data, forKey: key) }
    }
}
