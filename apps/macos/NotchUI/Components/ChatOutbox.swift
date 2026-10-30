import Foundation

/// The messages you sent from the Chats tab that their app has not shown back yet, so a message is in the chat the moment
/// you press Return, the same for every app: with a clock while it goes, one tick once its app took it, and gone as soon
/// as the app's own copy of it is in the chat. One that fails leaves at once (its text goes back into the field).
@MainActor
final class ChatOutbox: ObservableObject {
    static let shared = ChatOutbox()

    struct Item: Equatable {
        let id: String
        let text: String
        let quote: BubbleQuote?
        let date: Date
        /// How many of your messages with this text the chat showed when it went, counting the ones still on their way:
        /// one more than that is this one.
        let baseline: Int
        /// When its app took it; nil while it goes.
        var sent: Date?
    }

    /// By the Chats tab's chat id, oldest first.
    @Published private(set) var items: [String: [Item]] = [:]

    /// How long a sent message waits for its app's copy before Nook stops showing it (an app that changed its text, or
    /// one Nook does not read back).
    nonisolated static let patience: TimeInterval = 120
    /// The difference allowed between this Mac's clock and the time the app gives your message.
    nonisolated private static let clockSlack: TimeInterval = 10

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Shows `text` in `chat` now; `shown` is what the chat shows at this moment. Returns the id to report back with.
    func add(_ text: String, quote: BubbleQuote?, chat: String, shown: [ChatBubble]) -> String {
        let waiting = items[chat] ?? []
        let baseline = Self.mine(text, in: shown) + waiting.filter { $0.text == text }.count
        let item = Item(id: "outbox:" + UUID().uuidString, text: text, quote: quote, date: Date(), baseline: baseline)
        items[chat, default: []].append(item)
        return item.id
    }

    /// Its app took it: one tick, until the app's copy is in the chat.
    func sent(_ id: String, chat: String) {
        guard let index = items[chat]?.firstIndex(where: { $0.id == id }) else { return }
        items[chat]?[index].sent = Date()
    }

    /// It did not go: it leaves the chat.
    func failed(_ id: String, chat: String) {
        items[chat]?.removeAll { $0.id == id }
        if items[chat]?.isEmpty == true { items[chat] = nil }
    }

    /// `shown` with the messages still on their way after it. Those whose app's copy is in `shown` already, or that
    /// waited too long, are left out, and forgotten after this redraw.
    func bubbles(_ shown: [ChatBubble], chat: String, now: Date = Date()) -> [ChatBubble] {
        guard let waiting = items[chat], !waiting.isEmpty else { return shown }
        let open = Self.unanswered(waiting, shown: shown, now: now)
        if open.count < waiting.count {
            let keep = Set(open.map(\.id))
            DispatchQueue.main.async { [weak self] in
                self?.items[chat]?.removeAll { !keep.contains($0.id) }
                if self?.items[chat]?.isEmpty == true { self?.items[chat] = nil }
            }
        }
        guard !open.isEmpty else { return shown }
        return shown + open.map { item in
            ChatBubble(id: item.id, text: item.text, time: Self.time.string(from: item.date), date: item.date, fromMe: true,
                       ticks: item.sent == nil ? .pending : .sent, quote: item.quote, local: true)
        }
    }

    /// The items whose app's copy `shown` does not have yet: one is there once the chat shows more of your messages with
    /// its text than when it went, or as many of your messages from after it went as there are items up to it (an app
    /// that wrote the text its own way).
    nonisolated static func unanswered(_ items: [Item], shown: [ChatBubble], now: Date) -> [Item] {
        var open: [Item] = []
        for (position, item) in items.enumerated() {
            if let sent = item.sent, now.timeIntervalSince(sent) > patience { continue }
            if mine(item.text, in: shown) > item.baseline { continue }
            let since = item.date.addingTimeInterval(-clockSlack)
            let later = shown.filter { $0.fromMe && !$0.local && ($0.date.map { $0 >= since } ?? false) }.count
            if later > position { continue }
            open.append(item)
        }
        return open
    }

    /// How many of your messages in `shown` say `text`.
    nonisolated private static func mine(_ text: String, in shown: [ChatBubble]) -> Int {
        shown.filter { $0.fromMe && !$0.local && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text }.count
    }
}
