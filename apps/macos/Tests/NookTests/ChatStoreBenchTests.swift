import XCTest

/// Measures the archive on a real inbox (a copy of `chat-inbox.json` at the path in NOOK_CHAT_BENCH) and on 200 chats of
/// NOOK_CHAT_BENCH_PER messages (5,000: a million). Runs only when asked, and prints sizes and times, never a message:
///   NOOK_CHAT_BENCH=<copy of chat-inbox.json> scripts/core-tests.sh --filter ChatStoreBenchTests
/// On 2026-11-11: 265 bytes per message, a page back in 0.14 ms, a search in 7–8 ms over a million messages.
final class ChatStoreBenchTests: XCTestCase {
    func testBench() throws {
        guard let path = ProcessInfo.processInfo.environment["NOOK_CHAT_BENCH"] else { throw XCTSkip("no bench") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Real inbox.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var t = Date()
        let inbox = try JSONDecoder().decode(ChatInbox.self, from: data)
        let jsonDecode = Date().timeIntervalSince(t)
        let count = inbox.threads.values.reduce(0) { $0 + $1.messages.count }
        let store = try XCTUnwrap(ChatStore(url: folder.appendingPathComponent("real.sqlite")))
        t = Date()
        XCTAssertTrue(store.apply(from: nil, to: inbox))
        let migrate = Date().timeIntervalSince(t)
        store.maintain()
        t = Date()
        _ = store.loadInbox(window: 50)
        let load = Date().timeIntervalSince(t)
        t = Date()
        _ = try JSONEncoder().encode(inbox)
        let jsonEncode = Date().timeIntervalSince(t)
        print("BENCH real: chats=\(inbox.threads.count) messages=\(count) json=\(data.count)B sqlite=\(store.fileBytes)B migrate=\(migrate)s load=\(load)s jsonDecode=\(jsonDecode)s jsonEncodeWhole=\(jsonEncode)s")

        // A million messages.
        let big = try XCTUnwrap(ChatStore(url: folder.appendingPathComponent("big.sqlite")))
        let words = ["morgen", "vergadering", "boodschappen", "voetbalploeg", "verjaardag", "trein", "vertraging", "lunch", "project", "deadline", "foto", "vakantie", "koffie", "Café", "afspraak", "bellen"]
        var rng = SystemRandomNumberGenerator()
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        t = Date()
        for chat in 0..<200 {
            var thread = InboxThread(id: "telegram|chat\(chat)", app: "telegram", name: "Chat \(chat)")
            thread.bridged = true
            var batch = ChatInbox()
            let per = Int(ProcessInfo.processInfo.environment["NOOK_CHAT_BENCH_PER"] ?? "5000")!
            thread.messages = (0..<per).map { i in
                let text = (0..<Int.random(in: 4...14, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
                return InboxMessage(id: "c\(chat)m\(i)", sender: i % 3 == 0 ? "" : "Persoon \(i % 7)", text: text,
                                    date: start.addingTimeInterval(Double(i) * 300 + Double(chat)))
            }
            batch.threads[thread.id] = thread
            XCTAssertTrue(big.apply(from: chat == 0 ? nil : batch.emptied, to: batch), "one chat at a time, the others left as they are")
        }
        let write = Date().timeIntervalSince(t)
        big.maintain()
        t = Date()
        let loaded = big.loadInbox(window: 50)
        let bigLoad = Date().timeIntervalSince(t)
        let first = try XCTUnwrap(loaded?.inbox.threads["telegram|chat7"]?.messages.first)
        t = Date()
        var page = big.older("telegram|chat7", before: first.date, excluding: [first.id], limit: 50)
        for _ in 0..<20 where !page.isEmpty { page = big.older("telegram|chat7", before: page[0].date, excluding: [page[0].id], limit: 50) }
        let pageTime = Date().timeIntervalSince(t) / 21
        t = Date()
        let hits = big.search(["ploeg"], limit: 60)
        let search1 = Date().timeIntervalSince(t)
        t = Date()
        let hits2 = big.search(["vertraging", "cafe"], limit: 60)
        let search2 = Date().timeIntervalSince(t)
        t = Date()
        _ = big.search(["xyzzy"], limit: 60)
        let searchMiss = Date().timeIntervalSince(t)
        print("BENCH million: sqlite=\(big.fileBytes)B (\(big.fileBytes / 1_000_000)B/msg) write=\(write)s load=\(bigLoad)s page=\(pageTime * 1000)ms search1=\(search1 * 1000)ms(\(hits.count) chats) search2=\(search2 * 1000)ms(\(hits2.count)) miss=\(searchMiss * 1000)ms")
    }
}

private extension ChatInbox {
    /// The same inbox without its chats: a save from it writes its chats and leaves every other one as it is.
    var emptied: ChatInbox {
        var inbox = self
        inbox.threads = [:]
        return inbox
    }
}
