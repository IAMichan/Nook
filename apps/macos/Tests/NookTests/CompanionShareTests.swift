import XCTest

/// What other apps share to Nook, files with a message, and snoozing to a moment (`CompanionShare.swift`).
final class CompanionShareTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func jpeg(_ size: Int) -> CompanionImage {
        CompanionImage(jpeg: (Data([0xFF, 0xD8, 0xFF]) + Data(count: size - 3)).base64EncodedString())
    }

    // MARK: Files

    func testFileNamesAreMadeSafe() {
        XCTAssertEqual(CompanionFile.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(CompanionFile.safeName("C:\\Users\\a\\report.pdf"), "report.pdf")
        XCTAssertEqual(CompanionFile.safeName("..hidden"), "hidden")
        XCTAssertEqual(CompanionFile.safeName("a\u{0}b.txt"), "ab.txt")
        XCTAssertNil(CompanionFile.safeName("..."))
        let long = String(repeating: "n", count: 120) + ".markdown"
        XCTAssertEqual(CompanionFile.safeName(long)?.count, 80)
        XCTAssertTrue(CompanionFile.safeName(long)?.hasSuffix(".markdown") ?? false)
    }

    func testFilesAndPicturesFitOneMessageTogether() {
        let file = CompanionFile(name: "notes.txt", bytes: Data(count: 100 * 1024))
        XCTAssertTrue(CompanionFile.fits(images: [], files: [file]))
        XCTAssertTrue(CompanionFile.fits(images: [jpeg(60 * 1024)], files: [file]))
        XCTAssertFalse(CompanionFile.fits(images: [jpeg(90 * 1024)], files: [file]), "together over the limit")
        XCTAssertFalse(CompanionFile.fits(images: [], files: [file, file]), "one file per message")
        XCTAssertFalse(CompanionFile.fits(images: [], files: [CompanionFile(name: "big.bin", bytes: Data(count: 151 * 1024))]))
        XCTAssertFalse(CompanionFile.fits(images: [], files: [CompanionFile(name: "...", bytes: Data(count: 10))]))
        XCTAssertNil(CompanionFile(name: "empty", bytes: Data()).bytes)
    }

    // MARK: Snooze

    func testASnoozeToAMomentIsAheadAndAtMostAMonth() {
        XCTAssertEqual(CompanionSnooze.end(CompanionSnooze.text(now.addingTimeInterval(7200)), now: now), now.addingTimeInterval(7200))
        XCTAssertNil(CompanionSnooze.end(CompanionSnooze.text(now.addingTimeInterval(10)), now: now), "too close")
        XCTAssertNil(CompanionSnooze.end(CompanionSnooze.text(now.addingTimeInterval(-60)), now: now))
        XCTAssertNil(CompanionSnooze.end("tomorrow", now: now))
        XCTAssertNil(CompanionSnooze.end(nil, now: now))
        XCTAssertEqual(CompanionSnooze.end(CompanionSnooze.text(now.addingTimeInterval(90 * 86_400)), now: now),
                       now.addingTimeInterval(CompanionSnooze.maxAhead))
        XCTAssertTrue(SessionAction.allCases.contains(.snoozeUntil))
        XCTAssertTrue(SessionAction.allCases.contains(.snoozeLimitReset))
    }

    func testDigestsCarryTheLimitResetAndStillReadWithout() throws {
        var digest = SessionDigest(id: "s", title: "t", agent: "Codex", attention: "limited", folder: "f", branch: nil, updated: 0,
                                   excerpt: "", items: [])
        digest.limitResetsAt = 1234
        XCTAssertEqual(try JSONDecoder().decode(SessionDigest.self, from: JSONEncoder().encode(digest)).limitResetsAt, 1234)
        let old = #"{"id":"s","title":"t","agent":"a","attention":"idle","folder":"f","updated":0,"excerpt":"","items":[]}"#
        XCTAssertNil(try JSONDecoder().decode(SessionDigest.self, from: Data(old.utf8)).limitResetsAt)
    }

    // MARK: Sharing

    func testWordsKeepTheNoteThenWhatWasSharedOnce() {
        XCTAssertEqual(SharedItem.words(note: " Look at this ", shared: ["https://a.b/c", "https://a.b/c", ""]),
                       "Look at this\n\nhttps://a.b/c")
        XCTAssertEqual(SharedItem.words(note: "", shared: ["text"]), "text")
    }

    func testEachTargetBecomesItsRequestWithTheItemsId() throws {
        let start = SharedItem(id: "share-1", mac: "m", created: now, target: .newSession(agent: "claude", project: "/p", worktree: true),
                               text: "Fix this", images: [jpeg(1000)])
        let request = try XCTUnwrap(start.request())
        XCTAssertEqual(request.id, "share-1", "the Mac carries it out once, however often it is sent")
        XCTAssertEqual(request.op, .start)
        XCTAssertEqual(request.launch, LaunchRequest(agent: "claude", project: "/p", task: "Fix this", worktree: true))
        XCTAssertEqual(request.images?.count, 1)

        let file = CompanionFile(name: "log.txt", bytes: Data("boom".utf8))
        let send = try XCTUnwrap(SharedItem(mac: "m", created: now, target: .session("s1"), text: "", files: [file]).request())
        XCTAssertEqual(send.op, .send)
        XCTAssertEqual(send.session, "s1")
        XCTAssertEqual(send.attachments, [file], "a file alone may go to a session")

        let ask = try XCTUnwrap(SharedItem(mac: "m", created: now, target: .nookChat, text: "What is this?").request())
        XCTAssertEqual(ask.op, .ask)
        XCTAssertNil(ask.conversation, "a new chat")
    }

    func testWhatCannotGoSaysWhy() {
        XCTAssertEqual(SharedItem(mac: "m", target: .newSession(agent: "a", project: "/p", worktree: false), text: " ").problem, .needsWords)
        XCTAssertEqual(SharedItem(mac: "m", target: .nookChat, text: "hi", images: [jpeg(100)]).problem, .nookTakesNoFiles)
        XCTAssertEqual(SharedItem(mac: "m", target: .session("s"), text: "hi",
                                  files: [CompanionFile(name: "a", bytes: Data(count: 200 * 1024))]).problem, .tooBig)
        XCTAssertNil(SharedItem(mac: "m", target: .session("s"), text: "", images: [jpeg(100)]).problem)
        XCTAssertNil(SharedItem(mac: "m", target: .nookChat, text: " ").request())
    }

    func testTheQueueHandsEachMacItsOwnAndDropsWhatWaitedTooLong() {
        var queue = ShareQueue()
        let old = SharedItem(id: "old", mac: "a", created: now.addingTimeInterval(-2 * 3600), target: .nookChat, text: "late")
        let message = SharedItem(id: "msg", mac: "a", created: now.addingTimeInterval(-2 * 3600), target: .session("s"), text: "still fine")
        let fresh = SharedItem(id: "new", mac: "a", created: now.addingTimeInterval(-60), target: .nookChat, text: "now")
        let other = SharedItem(id: "b1", mac: "b", created: now, target: .nookChat, text: "other Mac")
        XCTAssertTrue(queue.add(fresh))
        XCTAssertTrue(queue.add(old))
        XCTAssertTrue(queue.add(message))
        XCTAssertTrue(queue.add(other))
        XCTAssertTrue(queue.add(fresh), "the same item twice is kept once")
        XCTAssertFalse(queue.add(SharedItem(mac: "a", target: .nookChat, text: "")), "an item that cannot go is not kept")
        let taken = queue.take(for: "a", now: now)
        XCTAssertEqual(taken.ready.map(\.id), ["msg", "new"], "oldest first; a message to a session may wait a day")
        XCTAssertEqual(taken.expired.map(\.id), ["old"], "a question to Nook waits an hour at most, as in the outbox")
        XCTAssertEqual(queue.items.map(\.id), ["b1"])
        queue.keep(macs: ["a"])
        XCTAssertTrue(queue.items.isEmpty, "a Mac no longer paired takes its shares with it")
    }

    func testTheQueueIsBounded() {
        var queue = ShareQueue()
        for index in 0..<ShareQueue.maxItems { XCTAssertTrue(queue.add(SharedItem(id: "\(index)", mac: "m", target: .nookChat, text: "x"))) }
        XCTAssertFalse(queue.add(SharedItem(mac: "m", target: .nookChat, text: "one too many")))
    }

    func testShareTargetsListSessionsThatTakeMessagesNewestFirst() {
        var terminal = SessionDigest(id: "t", title: "T", agent: "Claude", attention: "idle", folder: "f", branch: nil, updated: 9,
                                     excerpt: "", items: [])
        terminal.canSend = false
        let older = SessionDigest(id: "o", title: "O", agent: "Codex", attention: "idle", folder: "f", branch: nil, updated: 1, excerpt: "", items: [])
        let newer = SessionDigest(id: "n", title: "N", agent: "Codex", attention: "idle", folder: "f", branch: nil, updated: 5, excerpt: "", items: [])
        XCTAssertEqual(ShareTargets.sessions([older, terminal, newer]).map(\.id), ["n", "o"])
    }
}
