import XCTest

/// What a screen reader hears from the open session (`AgentAnnouncements`) and how it is spaced out
/// (`AnnouncementPacer`). Texts are compared through `tr`, so the checks hold with and without the real tables.
final class AgentAnnouncementsTests: XCTestCase {
    private typealias Snapshot = AgentAnnouncementSnapshot

    private func reply(_ id: String, _ text: String, finished: Bool = true) -> Snapshot.Reply {
        .init(id: id, text: text, finished: finished)
    }

    // MARK: What is said

    func testTheFirstSnapshotIsASilentBaseline() {
        let first = AgentAnnouncements.next(nil, Snapshot(status: .working, step: "Editing a.swift", replies: [reply("r", "hi")]),
                                            level: .everything, author: "Codex")
        XCTAssertEqual(first.messages, [])
        XCTAssertNil(first.step)
    }

    func testAFinishedReplyIsSaidOnceWithItsAuthor() {
        var memory = AgentAnnouncements.next(nil, Snapshot(status: .working), level: .replies, author: "Pi").memory
        // Still being written: nothing yet.
        var next = AgentAnnouncements.next(memory, Snapshot(status: .working, replies: [reply("r", "Half", finished: false)]),
                                           level: .replies, author: "Pi")
        XCTAssertEqual(next.messages, [])
        memory = next.memory
        next = AgentAnnouncements.next(memory, Snapshot(status: .idle, replies: [reply("r", "**Done**, tests pass")]),
                                       level: .replies, author: "Pi")
        XCTAssertEqual(next.messages, [tr("ws.announce.reply", "Pi", "Done, tests pass")])
        next = AgentAnnouncements.next(next.memory, Snapshot(status: .idle, replies: [reply("r", "**Done**, tests pass")]),
                                       level: .replies, author: "Pi")
        XCTAssertEqual(next.messages, [])
    }

    func testHistoryIsNeverReadOut() {
        let memory = AgentAnnouncements.next(nil, .idle, level: .replies, author: "Pi").memory
        // The transcript of an ended session arrives after it opened: not news.
        let next = AgentAnnouncements.next(memory, Snapshot(status: .idle, replies: [reply("r", "old answer")]),
                                           level: .replies, author: "Pi")
        XCTAssertEqual(next.messages, [])
    }

    func testWhatWaitsOnYouIsSaidWhenItStarts() {
        let memory = AgentAnnouncements.next(nil, Snapshot(status: .working), level: .replies, author: "Gemini CLI").memory
        let asked = AgentAnnouncements.next(memory, Snapshot(status: .question), level: .replies, author: "Gemini CLI")
        XCTAssertEqual(asked.messages, [tr("ws.announce.question", "Gemini CLI")])
        XCTAssertEqual(AgentAnnouncements.next(asked.memory, Snapshot(status: .question), level: .replies, author: "Gemini CLI").messages, [])
        let approval = AgentAnnouncements.next(memory, Snapshot(status: .approval), level: .replies, author: "Claude Code")
        XCTAssertEqual(approval.messages, [tr("ws.announce.approval", "Claude Code")])
    }

    func testStepsOnlyAtTheirLevelAndOnlyWhenNew() {
        let memory = AgentAnnouncements.next(nil, Snapshot(status: .working, step: "Reading a"), level: .everything, author: "A").memory
        let next = AgentAnnouncements.next(memory, Snapshot(status: .working, step: "Editing b"), level: .everything, author: "A")
        XCTAssertEqual(next.step, "Editing b")
        XCTAssertNil(AgentAnnouncements.next(next.memory, Snapshot(status: .working, step: "Editing b"), level: .everything, author: "A").step)
        XCTAssertNil(AgentAnnouncements.next(memory, Snapshot(status: .working, step: "Editing b"), level: .replies, author: "A").step)
        // Off says nothing at all.
        let off = AgentAnnouncements.next(memory, Snapshot(status: .approval, step: "x", replies: [reply("r", "y")]), level: .off, author: "A")
        XCTAssertEqual(off.messages, [])
        XCTAssertNil(off.step)
    }

    func testRepliesReadAsPlainWordsCutShort() {
        XCTAssertEqual(AgentAnnouncements.spoken("# Title\n- **one** and `two`\n[link](https://x.y)"), "Title one and two link")
        XCTAssertFalse(AgentAnnouncements.spoken("before\n```swift\nlet x = 1\n```\nafter").contains("let x"))
        let long = AgentAnnouncements.spoken(String(repeating: "word ", count: 400))
        XCTAssertLessThan(long.count, AgentAnnouncements.replyLimit + 80)
        XCTAssertTrue(long.hasSuffix(tr("ws.announce.more")))
    }

    // MARK: Snapshots from both timelines

    func testTranscriptSnapshotTakesTheLatestTurnsReplies() {
        let messages = [
            AgentChatMessage(id: "u1", fromUser: true, text: "first"),
            AgentChatMessage(id: "a1", fromUser: false, text: "old"),
            AgentChatMessage(id: "u2", fromUser: true, text: "second"),
            AgentChatMessage(id: "a2", fromUser: false, text: "on it"),
            AgentChatMessage(id: "t", kind: .tools, text: "", steps: []),
            AgentChatMessage(id: "a3", fromUser: false, text: "writing"),
        ]
        let snapshot = AgentAnnouncements.snapshot(messages, status: .working, step: nil)
        XCTAssertEqual(snapshot.replies.map(\.id), ["a2", "a3"])
        // The agent went on after the first: it is finished; the last is still being written.
        XCTAssertEqual(snapshot.replies.map(\.finished), [true, false])
        XCTAssertEqual(AgentAnnouncements.snapshot(messages, status: .idle, step: nil).replies.map(\.finished), [true, true])
    }

    func testRunSnapshotTakesTheLatestTurnsReplies() {
        let events = [RunEvent(kind: .user, text: "go"), RunEvent(kind: .assistant, text: "first"),
                      RunEvent(kind: .tool, text: "Bash · ls", tool: "Bash"), RunEvent(kind: .assistant, text: "second")]
        let snapshot = AgentAnnouncements.snapshot(events, status: .working, step: nil)
        XCTAssertEqual(snapshot.replies.map(\.text), ["first", "second"])
        XCTAssertEqual(snapshot.replies.map(\.finished), [true, false])
    }

    // MARK: Pacing

    @MainActor
    func testAStepWaitsForTheReplyAndANewerOneTakesItsPlace() {
        var clock = Date(timeIntervalSince1970: 0)
        var said: [String] = []
        var timers: [(at: Date, run: @MainActor () -> Void, cancelled: Bool)] = []
        let pacer = AnnouncementPacer(now: { clock }, schedule: { delay, work in
            timers.append((clock.addingTimeInterval(delay), work, false))
            let index = timers.count - 1
            return { timers[index].cancelled = true }
        }, speak: { said.append($0) })

        pacer.step("Reading a")
        XCTAssertEqual(said, ["Reading a"])
        // Within the gap the next step waits; a newer one replaces it.
        pacer.step("Editing b")
        pacer.step("Running tests")
        XCTAssertEqual(said, ["Reading a"])
        XCTAssertEqual(timers.count(where: { !$0.cancelled }), 1)
        clock = clock.addingTimeInterval(AnnouncementPacer.gap)
        for timer in timers where !timer.cancelled { timer.run() }
        XCTAssertEqual(said, ["Reading a", "Running tests"])

        // A reply is said at once and holds the next step for about as long as it takes to read.
        clock = clock.addingTimeInterval(10)
        pacer.say(["Pi: done", "Pi asks you a question"])
        XCTAssertEqual(said.last, "Pi: done. Pi asks you a question")
        timers.removeAll()
        pacer.step("Editing c")
        XCTAssertEqual(said.last, "Pi: done. Pi asks you a question")
        XCTAssertEqual(timers.count, 1)
        // Dropped when the agent moves on to something that is no step.
        pacer.step(nil)
        XCTAssertTrue(timers[0].cancelled)
        XCTAssertFalse(pacer.hasWaitingStep)
    }

    func testHoldGrowsWithTheTextWithinBounds() {
        XCTAssertEqual(AnnouncementPacer.hold(after: "ok"), AnnouncementPacer.gap)
        XCTAssertEqual(AnnouncementPacer.hold(after: String(repeating: "x", count: 10_000)), AnnouncementPacer.holdLimit)
        XCTAssertEqual(AnnouncementPacer.joined(["a", "b?", "c"]), "a. b? c")
    }
}
