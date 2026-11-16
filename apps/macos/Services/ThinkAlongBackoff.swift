import Foundation

/// How long Think Along waits after an offer: longer after each one you declined or left unanswered, up to two hours,
/// and back to normal once you accept one. Kept between launches, so a restart does not make Nook eager again.
/// The day's count of offers is the shared budget's (`InterruptionBudget`). Pure; tested in ThinkAlongBackoffTests.
struct ThinkAlongBackoff: Codable, Equatable, Sendable {
    static let baseGap: TimeInterval = 900
    static let maxGap: TimeInterval = 7200
    static let storageKey = "thinkAlongBackoff"

    /// Offers declined (or left unanswered) since the last one you accepted.
    private(set) var declines = 0
    /// Whether the last offer got an answer; one that went by unanswered counts as a no for the next gap.
    private(set) var answered = true
    private(set) var lastOffer: Date?

    init() {}

    init(stored: Data?) {
        self = stored.flatMap { try? JSONDecoder().decode(ThinkAlongBackoff.self, from: $0) } ?? ThinkAlongBackoff()
    }

    var stored: Data? { try? JSONEncoder().encode(self) }

    /// The wait after the last offer. The offer still out there without an answer counts already, so the next one
    /// waits the doubled time.
    var gap: TimeInterval {
        let noes = declines + (answered ? 0 : 1)
        return min(Self.maxGap, Self.baseGap * pow(2, Double(min(noes, 4))))
    }

    /// Whether the gap since the last offer has passed.
    func allows(now: Date) -> Bool {
        guard let lastOffer else { return true }
        return now.timeIntervalSince(lastOffer) >= gap
    }

    mutating func offered(at now: Date) {
        if !answered { declines += 1 }
        answered = false
        lastOffer = now
    }

    mutating func accepted() {
        declines = 0
        answered = true
    }

    mutating func declined() {
        declines += 1
        answered = true
    }
}
