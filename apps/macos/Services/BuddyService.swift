import Foundation
import CoreGraphics

/// The state behind Nook's own moments (`AppModel+Buddy`): what you have been doing, what he already shared, and how
/// many agent runs finished. Kept apart from `AppModel`, which only composes it.
@MainActor
final class BuddyService {
    private static let ledgerKey = "buddy.ledger"
    /// Counted every finished turn until 2026-11, which made "500 agent runs" out of a few dozen sessions.
    private static let legacyFinishedKey = "buddy.finishedTotal"
    private static let finishedKey = "buddy.finishedSessions"
    private static let countedKey = "buddy.countedSessions"
    /// Sessions remembered as counted; older ones are long finished and will not come back.
    private static let countedLimit = 1000

    var activity = BuddyActivity()
    /// What Nook already shared; saved between launches so a restart does not repeat the morning greeting.
    var ledger: BuddyLedger {
        didSet { UserDefaults.standard.set(ledger.stored, forKey: Self.ledgerKey) }
    }
    /// Agent sessions finished, ever: for the milestones. A session counts once, however many turns it takes.
    private(set) var finishedTotal: Int {
        didSet { UserDefaults.standard.set(finishedTotal, forKey: Self.finishedKey) }
    }
    /// The sessions already in `finishedTotal`, oldest first.
    private var counted: [String] {
        didSet { UserDefaults.standard.set(counted, forKey: Self.countedKey) }
    }
    /// When recent agent sessions finished: "two agents finished while you were away".
    private var finishes: [(at: Date, session: String)] = []

    init() {
        var ledger = BuddyLedger(stored: UserDefaults.standard.data(forKey: Self.ledgerKey))
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.legacyFinishedKey) != nil {
            // The old count was turns, not sessions: start over, milestones included.
            defaults.removeObject(forKey: Self.legacyFinishedKey)
            ledger.milestones = []
            defaults.set(ledger.stored, forKey: Self.ledgerKey)
        }
        self.ledger = ledger
        finishedTotal = defaults.integer(forKey: Self.finishedKey)
        counted = defaults.stringArray(forKey: Self.countedKey) ?? []
    }

    /// A session finished a turn. Only its first finish counts towards the total.
    func noteFinishedAgent(session: String, at now: Date = Date()) {
        if !counted.contains(session) {
            finishedTotal += 1
            counted = Array((counted + [session]).suffix(Self.countedLimit))
        }
        finishes.append((now, session))
        if finishes.count > 100 { finishes.removeFirst(finishes.count - 100) }
    }

    /// Agent sessions that finished between the two moments, each counted once.
    func finished(from start: Date, to end: Date) -> Int {
        Set(finishes.filter { $0.at > start && $0.at <= end }.map(\.session)).count
    }

    /// Seconds since the last keyboard, mouse or trackpad input anywhere on the Mac. Reading it needs no permission.
    static func systemIdleSeconds() -> TimeInterval {
        SystemLoad.idleSeconds
    }
}
