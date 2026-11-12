import Foundation

/// A command that changes a session (stop, steer, send, a decision, an answer, a start) and may reach Nook more than once:
/// the phone sends it again from its outbox after a dropped connection, over a second route, or after a refusal for its
/// clock, always with the same id. Foundation only, tested on its own.
struct SessionCommand: Equatable, Sendable {
    /// Unique per command the sender issued and kept on every resend, with where it came from in front ("phone:…"), so
    /// two senders never share one.
    var id: String
    /// The turn the sender saw running when it issued the command (`SessionDigest.turn`): a Stop or a steer meant for that
    /// turn leaves a turn that started after it alone. Nil from a sender that does not say, which acts on what runs now.
    var turn: String? = nil

    /// A command from the paired phone: its request id, which every resend keeps.
    static func phone(_ requestID: String, turn: String? = nil) -> SessionCommand? {
        let clean = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let seen = turn?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionCommand(id: "phone:" + String(clean.prefix(200)), turn: seen?.isEmpty == false ? seen : nil)
    }
}

/// What a session command did, kept as its receipt: a repeat of the command gets this back and does nothing.
enum SessionCommandOutcome: String, Codable, Sendable {
    case stopped, sent, queued, steered, decided, answered, started
    /// Did nothing on purpose: the turn it was meant for had ended, and a later one is not its business.
    case stale
}

/// Whether a command issued while the sender saw turn `issuedFor` may act on the turn running now.
enum SessionTurnCheck {
    static func applies(issuedFor: String?, current: String?) -> Bool {
        guard let issuedFor else { return true }
        return issuedFor == current
    }
}

/// The receipts of session commands Nook carried out: a command id seen before gets its first outcome back instead of
/// running again. Also a command that did nothing (a Stop that came after its turn ended) leaves a receipt, so a replay of
/// it can never stop work that started after it. Bounded (least recently used goes first) and short-lived; kept across a
/// restart of Nook (`load`, `save`, a few kilobytes), because the phone's outbox sends again after one.
struct SessionCommandReceipts: Codable, Equatable, Sendable {
    struct Receipt: Codable, Equatable, Sendable {
        var id: String
        var outcome: SessionCommandOutcome
        /// What the command made, if anything: the session a start created.
        var created: String?
        var at: Date
    }

    static let capacity = 512
    /// As long as the phone keeps a command in its outbox (a day), with an hour to spare.
    static let lifetime: TimeInterval = 25 * 3600

    /// Least recently used first.
    private(set) var receipts: [Receipt] = []

    init() {}

    /// The receipt of a command, while it is kept.
    func receipt(_ id: String, now: Date = Date()) -> Receipt? {
        guard let receipt = receipts.last(where: { $0.id == id }), now.timeIntervalSince(receipt.at) <= Self.lifetime else { return nil }
        return receipt
    }

    /// Keeps what a command did. A command already kept keeps its first outcome.
    @discardableResult
    mutating func record(_ id: String, _ outcome: SessionCommandOutcome, created: String? = nil, now: Date = Date()) -> Receipt {
        receipts.removeAll { now.timeIntervalSince($0.at) > Self.lifetime }
        if let index = receipts.lastIndex(where: { $0.id == id }) {
            let first = receipts.remove(at: index)
            receipts.append(first)
            return first
        }
        let receipt = Receipt(id: id, outcome: outcome, created: created, at: now)
        receipts.append(receipt)
        if receipts.count > Self.capacity { receipts.removeFirst(receipts.count - Self.capacity) }
        return receipt
    }

    /// The receipts kept at `url`; none when the file is missing or unreadable.
    static func load(from url: URL, now: Date = Date()) -> SessionCommandReceipts {
        guard let data = try? Data(contentsOf: url),
              var stored = try? JSONDecoder().decode(SessionCommandReceipts.self, from: data) else { return SessionCommandReceipts() }
        stored.receipts.removeAll { now.timeIntervalSince($0.at) > lifetime }
        if stored.receipts.count > capacity { stored.receipts.removeFirst(stored.receipts.count - capacity) }
        return stored
    }

    /// The file as `save` writes it: only you may read it.
    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func save(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
