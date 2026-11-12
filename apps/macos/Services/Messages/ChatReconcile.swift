import Foundation

/// Laying a chat's history as its app has it now beside what Nook's archive holds of the same stretch, a page at a time
/// (`ChatStore.reconcile`): how holes close (messages Nook never got, while it was not running or a read brought only the
/// newest), how an edit of an old message reaches the archive, and how a deletion does in an app that only leaves the
/// message out. Foundation only, so it can be tested anywhere.
enum ChatReconcile {
    /// One page of a chat's history from its app.
    struct Page: Sendable {
        /// The messages the app has before `high`, back to the oldest of them, with no gaps between them.
        var messages: [InboxMessage]
        /// Messages the app says were deleted (some apps list them beside the page).
        var deleted: [String] = []
        /// The stretch the page covers ends here (the message it was asked from is at this time).
        var high: Date
        /// The app leaves a message deleted for everyone out of its history (Slack, Telegram): one stored in the stretch
        /// the page covers that the page lacks was deleted.
        var omitsDeleted = false
        /// The app changes a message's words only by an edit but does not mark it (`ChatBridge.historyTextChangeIsEdit`).
        var textChangeIsEdit = false
        /// Messages of the stretch the app now keeps as deleted under an id of their own (Mail's Trash): the stored one
        /// with the same time and first line is marked deleted (`gone(_:like:)`).
        var gone: [InboxMessage] = []

        /// Where the stretch the page covers starts: its oldest message, or the oldest the app keeps as deleted.
        var low: Date? { (messages.map(\.date) + gone.map(\.date)).min() }
    }

    /// The stored messages that are the ones the app keeps as deleted under another id: from the same side, within two
    /// seconds, with the same first line (a mail's subject).
    static func gone(_ stored: [InboxMessage], like gone: [InboxMessage]) -> [String] {
        stored.filter { message in
            !message.isDeleted && gone.contains { other in
                other.isMine == message.isMine && abs(other.date.timeIntervalSince(message.date)) <= sameMoment
                    && firstLine(other.text) == firstLine(message.text)
            }
        }.map(\.id)
    }

    /// How far apart two copies of one message may be dated.
    static let sameMoment: TimeInterval = 2

    private static func firstLine(_ text: String) -> Substring {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }

    /// A page's message over what is stored of it, marked edited when its app's words changed and the app does not say.
    static func marked(_ message: InboxMessage, over stored: InboxMessage?, textChangeIsEdit: Bool) -> InboxMessage {
        guard textChangeIsEdit, let stored, !stored.isDeleted, !message.isDeleted, !stored.text.isEmpty,
              !message.text.isEmpty, stored.text != message.text else { return message }
        var message = message
        message.edited = true
        return message
    }

    /// The stored messages of the stretch a page covers (strictly between its oldest message and its end) that the page
    /// lacks: deleted in the app. Never your own (a message of yours that went missing would lose its text) and never one
    /// only a notification brought (it has no id of the app's own), nor a line about the group or one already deleted.
    static func absent(_ stored: [InboxMessage], from page: [InboxMessage]) -> [String] {
        let ids = Set(page.map(\.id))
        return stored.filter { !ids.contains($0.id) && !$0.isMine && !$0.isDeleted && !$0.isNotice && !isNotice($0.id) }
            .map(\.id)
    }

    /// The stored messages a notification brought ("n" and its record) that the page has under the app's own id: the
    /// same words from the same person within `ChatInbox.sameMessageWindow`. Only the app's copy stays.
    static func copies(_ stored: [InboxMessage], of page: [InboxMessage]) -> [String] {
        stored.filter { notice in
            isNotice(notice.id) && page.contains { message in
                !message.text.isEmpty && message.text == notice.text
                    && abs(message.date.timeIntervalSince(notice.date)) < ChatInbox.sameMessageWindow
            }
        }.map(\.id)
    }

    /// An id Nook gave a message a notification brought (`ChatCaptureService`: "n" and the notification's record).
    static func isNotice(_ id: String) -> Bool {
        id.count > 1 && id.first == "n" && id.dropFirst().allSatisfy(\.isNumber)
    }
}
