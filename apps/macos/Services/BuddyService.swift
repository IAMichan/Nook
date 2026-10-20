import Foundation
import Combine
import CoreGraphics

/// The state behind Nook's own moments (`AppModel+Buddy`): what you have been doing, what he already shared, and how
/// many agent runs finished. Kept apart from `AppModel`, which only composes it.
@MainActor
final class BuddyService {
    private static let ledgerKey = "buddy.ledger"
    private static let finishedKey = "buddy.finishedTotal"

    var activity = BuddyActivity()
    /// What Nook already shared; saved between launches so a restart does not repeat the morning greeting.
    var ledger: BuddyLedger {
        didSet { UserDefaults.standard.set(ledger.stored, forKey: Self.ledgerKey) }
    }
    /// Agent runs finished, ever: for the milestones.
    private(set) var finishedTotal: Int {
        didSet { UserDefaults.standard.set(finishedTotal, forKey: Self.finishedKey) }
    }
    /// When recent agent runs finished: "two agents finished while you were away".
    private var finishes: [Date] = []
    /// Until when Nook dresses for a party (a milestone, the last agent of a long run finishing).
    var celebratingUntil: Date?
    var bag = Set<AnyCancellable>()

    init() {
        ledger = BuddyLedger(stored: UserDefaults.standard.data(forKey: Self.ledgerKey))
        finishedTotal = UserDefaults.standard.integer(forKey: Self.finishedKey)
    }

    func noteFinishedAgent(at now: Date = Date()) {
        finishedTotal += 1
        finishes.append(now)
        if finishes.count > 100 { finishes.removeFirst(finishes.count - 100) }
    }

    /// Agent runs that finished between the two moments.
    func finished(from start: Date, to end: Date) -> Int {
        finishes.filter { $0 > start && $0 <= end }.count
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere on the Mac. Reading it needs no permission.
    static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}
