import Foundation

/// How a bridge asks its service for the chats that moved: several at the same time instead of one after another, the
/// same for every bridge that asks per chat (Nook's chat helper, Teams, Slack). A read of fifteen chats then takes about
/// as long as three of them, so the chats show soon after Nook starts and an opened chat is up to date at once.
///
/// Only the asking runs side by side. The answers come back in the chats' own order and the bridge goes through them one
/// after another as before, so what it remembers per chat (what it saw, what to read again) is written as it always was.
enum ChatParallel {
    /// Chats asked at the same time: enough to hide each request's wait, without asking a service for dozens at once.
    static let width = 6

    /// `fetch` for every item, at most `width` at a time, each answer in its item's place. Once an answer says to stop
    /// (`stops`: a lost sign-in, a rate limit), no further item is asked and those stay nil; the ones already under way
    /// still answer.
    @MainActor
    static func map<Item, Value>(_ items: [Item], width: Int = width, stops: @escaping (Value) -> Bool = { _ in false },
                                 _ fetch: @escaping @MainActor (Item) async -> Value) async -> [Value?] {
        let answers = Answers<Value>(count: items.count)
        guard !items.isEmpty else { return [] }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            while true {
                while running < max(width, 1), next < items.count, !answers.stopped {
                    let index = next
                    let item = items[index]
                    next += 1
                    running += 1
                    group.addTask { @MainActor in
                        let value = await fetch(item)
                        answers.values[index] = value
                        if stops(value) { answers.stopped = true }
                    }
                }
                guard running > 0, await group.next() != nil else { break }
                running -= 1
            }
        }
        return answers.values
    }

    /// One chat's answer: what the service said, a failure of that chat alone (a chat you left, a moment's hiccup: the
    /// others still count), or a refusal that ends the round (a lost sign-in or a rate limit: asking more only adds to it).
    enum Asked<Value> {
        case answered(Value)
        case failed(Error)
        case refused(Error)

        var ends: Bool {
            if case .refused = self { return true }
            return false
        }
    }

    /// `ask` with its failure sorted: a lost sign-in or a rate limit refuses the round, anything else fails this chat.
    @MainActor
    static func asking<Value>(_ ask: @MainActor () async throws -> Value) async -> Asked<Value> {
        do {
            return .answered(try await ask())
        } catch let error as NookError where error.kind == .auth || error.kind == .rateLimited {
            return .refused(error)
        } catch {
            return .failed(error)
        }
    }

    /// `fetch` for every item as `map` does, ending the round at the first refusal.
    @MainActor
    static func ask<Item, Value>(_ items: [Item], width: Int = width,
                                 _ fetch: @escaping @MainActor (Item) async -> Asked<Value>) async -> [Asked<Value>?] {
        await map(items, width: width, stops: { $0.ends }, fetch)
    }

    /// The answers as they come in; child tasks write here on the main actor, so nothing that is not `Sendable` crosses.
    @MainActor
    private final class Answers<Value> {
        var values: [Value?]
        var stopped = false
        init(count: Int) { values = Array(repeating: nil, count: count) }
    }
}
