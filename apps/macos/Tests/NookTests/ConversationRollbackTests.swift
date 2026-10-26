import XCTest

final class ConversationRollbackTests: XCTestCase {
    private func codexLog(_ ids: [String], thread: String = "t1") -> ConversationLog {
        var log = ConversationLog()
        log.noteSession(thread, provider: .codex, keepsHistory: false)
        for id in ids { log.startTurn(id: id) }
        return log
    }

    func testCapabilities() {
        XCTAssertTrue(RunProvider.claude.capabilities.canRollbackConversation)
        XCTAssertTrue(RunProvider.codex.capabilities.canRollbackConversation)
        for provider in RunProvider.allCases where provider.usesACP {
            XCTAssertFalse(provider.capabilities.canRollbackConversation, provider.rawValue)
        }
    }

    func testCodexDropsTheTurnsAfterTheMark() {
        let log = codexLog(["a", "b", "c"])
        var atOne = log
        atOne.rewind(to: ConversationMark(session: "t1", provider: .codex, turns: 1))
        let mark = ConversationMark(session: "t1", provider: .codex, turns: 1)
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: mark, log: log, currentSession: "t1"),
                       .codex(threadID: "t1", numTurns: 2, beforeTurnID: "b"))
        XCTAssertEqual(atOne.turnIDs, ["a"])
        XCTAssertEqual(atOne.turns, 1)
        // Nothing happened since the mark.
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: log.mark, log: log, currentSession: "t1"), .nothing)
    }

    func testCodexCountsATurnOnceAndMissingIDsDropTheTurnID() {
        var log = codexLog(["a", "a"])
        XCTAssertEqual(log.turns, 1, "the turn/start reply and turn/started name the same turn")
        log.startTurn()
        let mark = ConversationMark(session: "t1", provider: .codex, turns: 1)
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: mark, log: log, currentSession: "t1"),
                       .codex(threadID: "t1", numTurns: 1, beforeTurnID: nil))
    }

    func testCodexRefusesWhatItCannotCount() {
        let log = codexLog(["a", "b"])
        let mark = ConversationMark(session: "t1", provider: .codex, turns: 1)
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: mark, log: log, currentSession: "other"), .unavailable,
                       "another thread")
        var inexact = log
        inexact.exact = false
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: mark, log: inexact, currentSession: "t1"), .unavailable,
                       "a turn over codex exec was not counted")
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: nil, log: log, currentSession: "t1"), .unavailable,
                       "a checkpoint from before Nook followed the conversation")
        let claudeMark = ConversationMark(session: "t1", provider: .claude, turns: 1, head: "u")
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: claudeMark, log: log, currentSession: "t1"), .unavailable)
    }

    func testBackToBeforeTheFirstMessageStartsAfresh() {
        let log = codexLog(["a"])
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: .empty, log: log, currentSession: "t1"), .fresh)
        XCTAssertEqual(ConversationRollback.plan(provider: .claude, mark: .empty, log: nil, currentSession: "s"), .fresh)
        XCTAssertEqual(ConversationRollback.plan(provider: .claude, mark: .empty, log: nil, currentSession: nil), .nothing)
        // A thread with no turns yet at the mark: a new thread loses nothing.
        let opened = ConversationMark(session: "t1", provider: .codex, turns: 0)
        XCTAssertEqual(ConversationRollback.plan(provider: .codex, mark: opened, log: log, currentSession: "t1"), .fresh)
    }

    func testClaudeResumesAtTheMarkHead() {
        var log = ConversationLog()
        log.startTurn()
        log.noteSession("s1", provider: .claude, keepsHistory: true)
        XCTAssertEqual(log.turns, 1, "the session arrives after the turn started")
        log.noteHead("u1")
        let mark = log.mark
        log.startTurn()
        log.noteHead("u2")
        XCTAssertEqual(ConversationRollback.plan(provider: .claude, mark: mark, log: log, currentSession: "s1"),
                       .claudeResume(session: "s1", at: "u1"))
        // A copy (--fork-session) keeps what it copied; the old mark still names the original.
        log.noteSession("s2", provider: .claude, keepsHistory: true)
        XCTAssertEqual(log.head, "u2")
        XCTAssertEqual(ConversationRollback.plan(provider: .claude, mark: mark, log: log, currentSession: "s2"),
                       .claudeResume(session: "s1", at: "u1"))
        XCTAssertEqual(ConversationRollback.plan(provider: .claude, mark: log.mark, log: log, currentSession: "s2"), .nothing)
        let headless = ConversationMark(session: "s1", provider: .claude, turns: 1)
        XCTAssertEqual(ConversationRollback.plan(provider: .claude, mark: headless, log: log, currentSession: "s2"), .unavailable)
    }

    func testOtherAgentsAreFilesOnly() {
        let mark = ConversationMark(session: "x", provider: .gemini, turns: 1, head: "u")
        XCTAssertEqual(ConversationRollback.plan(provider: .gemini, mark: mark, log: nil, currentSession: "x"), .unavailable)
    }

    func testAnotherAgentStartsTheLogAgain() {
        var log = codexLog(["a", "b"])
        log.noteSession("s", provider: .claude, keepsHistory: true)
        XCTAssertEqual(log.provider, .claude)
        XCTAssertEqual(log.turns, 0)
        var thread = codexLog(["a"])
        thread.noteSession("t2", provider: .codex, keepsHistory: false)
        XCTAssertEqual(thread.turns, 0, "a new Codex thread")
    }

    func testPendingRollbacksAddUp() {
        let first = ConversationRollback.merge(nil, with: .codex(threadID: "t", numTurns: 2, beforeTurnID: "c"))
        let second = ConversationRollback.merge(first, with: .codex(threadID: "t", numTurns: 1, beforeTurnID: "b"))
        XCTAssertEqual(second, PendingRollback(threadID: "t", numTurns: 3, beforeTurnID: "b"))
        XCTAssertEqual(ConversationRollback.merge(second, with: .nothing), second)
        XCTAssertEqual(ConversationRollback.merge(second, with: .fresh), nil)
        let claude = ConversationRollback.merge(PendingRollback(resumeSession: "s", resumeAt: "u2"), with: .claudeResume(session: "s", at: "u1"))
        XCTAssertEqual(claude, PendingRollback(resumeSession: "s", resumeAt: "u1"))
        XCTAssertFalse(claude?.isCodex ?? true)
    }

    func testTrimAndTimeline() {
        let checkpoints = (0..<4).map { RunCheckpoint(ref: "refs/nook/checkpoints/x/\($0)", date: Date(timeIntervalSince1970: Double($0) * 10)) }
        let trimmed = ConversationRollback.trim(checkpoints, keepingThrough: 1)
        XCTAssertEqual(trimmed.kept.map(\.ref), ["refs/nook/checkpoints/x/0", "refs/nook/checkpoints/x/1"])
        XCTAssertEqual(trimmed.removedRefs, ["refs/nook/checkpoints/x/2", "refs/nook/checkpoints/x/3"])
        XCTAssertEqual(ConversationRollback.trim(checkpoints, keepingThrough: 9).removedRefs, [])

        let before = RunEvent(kind: .user, text: "one", date: Date(timeIntervalSince1970: 5))
        let after = RunEvent(kind: .user, text: "two", date: Date(timeIntervalSince1970: 15))
        var undone = RunEvent(kind: .assistant, text: "old", date: Date(timeIntervalSince1970: 16))
        undone.rolledBack = true
        XCTAssertEqual(ConversationRollback.rolledBackIDs([before, after, undone], after: Date(timeIntervalSince1970: 10)), [after.id])
    }

    func testOldDataDecodes() throws {
        let checkpoint = try JSONDecoder().decode(RunCheckpoint.self, from: Data(#"{"ref":"r","date":0}"#.utf8))
        XCTAssertNil(checkpoint.conversation)
        let event = try JSONDecoder().decode(RunEvent.self, from: JSONEncoder().encode(RunEvent(kind: .user, text: "x")))
        XCTAssertNil(event.rolledBack)
    }

    func testCodexRollbackParams() {
        XCTAssertEqual(JSONBox(CodexRPC.rollbackParams(threadID: "t", numTurns: 2)), JSONBox(["threadId": "t", "numTurns": 2] as [String: Any]))
        XCTAssertEqual(JSONBox(CodexRPC.revertParams(threadID: "t", beforeTurnID: "b")), JSONBox(["threadId": "t", "beforeTurnId": "b"]))
    }

    func testClaudeChainEntriesAndResumeFlag() {
        let assistant = ClaudeStreamParser.parse(#"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"Hi"}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(assistant, [.text("Hi"), .chainEntry("u1")])
        let nested = ClaudeStreamParser.parse(#"{"type":"assistant","uuid":"u2","message":{"content":[]},"parent_tool_use_id":"tool"}"#)
        XCTAssertEqual(nested, [], "a subagent's messages are not the main chain")
        let result = ClaudeStreamParser.parse(#"{"type":"user","uuid":"u3","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(result, [.toolResult(id: "t", output: "ok", isError: false), .chainEntry("u3")])

        let input = AgentCommand.Input(provider: .claude, executable: "/bin/claude", prompt: "go", model: "", mode: .agent,
                                       permission: .acceptEdits, instructions: "", workingDirectory: "/tmp",
                                       resumeSessionID: "s1", forkSession: true, resumeAt: "u1", accountEnvironment: [:], runID: UUID())
        let arguments = AgentCommand.spec(input).arguments
        XCTAssertTrue(arguments.contains("--fork-session"))
        let at = try? XCTUnwrap(arguments.firstIndex(of: "--resume-session-at"))
        XCTAssertEqual(at.map { arguments[$0 + 1] }, "u1")
    }
}
