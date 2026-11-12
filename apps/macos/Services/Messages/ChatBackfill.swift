import Foundation

/// Keeping the archive in step with each chat's app, in the background, a page at a time: each chat is walked from the
/// oldest message it shows down to its start, every page laid beside the archive (`ChatReconcile`), so holes close, the
/// whole history comes to this Mac, and edits and deletions of old messages reach it. Scrolling back and searching then
/// never wait for an app. Only while the Mac runs at full pace on power with room on its disk; files never come along.
enum ChatBackfill {
    /// How often the backfill looks for a chat to fill.
    static let tick: TimeInterval = 2
    /// Messages one batch asks for.
    static let step = 100
    /// Messages a page by count (`ChatBackfillBridge`) goes back over again, in case the archive left some out.
    static let overlap = 20
    /// Batches in a row that bring nothing older before a chat counts as complete: one empty answer can be a bridge busy
    /// with that chat.
    static let emptyToFinish = 3

    /// How long an app rests after a batch: its own data on this Mac is quick to read; a service is asked rarely, so it
    /// never notices.
    static func pause(local: Bool) -> TimeInterval { local ? 2 : 20 }

    /// How long after a chat's walk ended it is walked again: edits and deletions of old messages reach the archive
    /// within this. Each launch walks every chat once, so what came in while Nook was not running closes first.
    static let rewalk: TimeInterval = 6 * 60 * 60
    /// Less than any two messages apart: a stretch from a message on includes it.
    static let instant: TimeInterval = 0.000_5

    /// A walk back through one chat's history: the message the next page is asked before, and how many pages in a row
    /// brought nothing before it.
    struct Walk: Sendable {
        var cursor: Date
        var cursorID: String?
        var empty = 0
        /// An earlier walk reached the chat's start (`ChatStore.markComplete`).
        var reachedStartBefore = false
    }

    /// Runs only at full pace, not on a battery that is spared, and with at least the room `DiskSpace` warns at.
    static func allowed(_ plan: EnergyPlan, freeBytes: Int64?) -> Bool {
        plan.pace == .full && !plan.sparesBattery && (freeBytes ?? .max) > DiskSpace.lowBytes
    }

    /// How often a page by count (`page`) is asked again at another offset before its answer is taken as it is.
    static let pageTries = 6

    /// A page of a history its app gives by count from the newest (`fetch(offset)`, oldest first) that reaches back over
    /// `before`. `guess` is how many messages the archive holds of the chat; the page starts `overlap` short of that.
    /// When the archive missed messages, the page is all newer than `before` and the next starts further back; when it
    /// holds some the app lacks, the page is empty or all older (skipping some) and the next starts nearer.
    static func page(before: Date, guess: Int, limit: Int,
                     fetch: (Int) async throws -> [InboxMessage]) async throws -> [InboxMessage] {
        var offset = max(0, guess - overlap)
        var page: [InboxMessage] = []
        for _ in 0..<pageTries {
            page = try await fetch(offset)
            if page.isEmpty {
                guard offset > 0 else { return [] }
                offset = max(0, offset - limit)
            } else if page.count == limit, page.allSatisfy({ $0.date > before }) {
                offset += limit - overlap
            } else if offset > 0, page.allSatisfy({ $0.date < before }) {
                offset = max(0, offset - limit + overlap)
            } else {
                return page
            }
        }
        return page
    }

    /// What a page brought from before a walk's message, without it, and nothing from before you cleared the chat.
    static func messages(_ messages: [InboxMessage], below walk: Walk, removed: Date?) -> [InboxMessage] {
        messages.filter { message in
            message.id != walk.cursorID && message.date <= walk.cursor && removed.map { message.date > $0 } ?? true
        }
    }
}
