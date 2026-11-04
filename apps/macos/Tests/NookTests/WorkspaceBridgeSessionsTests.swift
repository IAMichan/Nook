import XCTest

/// The bridge's session tools: `session_search`, `session_organize` and `session_questions` (arguments, rules, answers).
final class WorkspaceBridgeSessionsTests: XCTestCase {
    private let id = UUID()

    private func run(_ mode: ExecutionMode = .agent, _ permission: PermissionPolicy = .acceptEdits) -> BridgeCaller {
        BridgeCaller(kind: .run(UUID()), agent: "Claude Code", title: "Fix", directory: "/Users/x/app", mode: mode, permission: permission)
    }

    // MARK: Policy

    func testSearchingIsReading() {
        XCTAssertEqual(BridgeTool.sessionSearch.effect, .read)
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionSearch, caller: run(.plan)), .allow)
    }

    func testOrganizingAsksUnlessFullRights() {
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionOrganize, caller: run()), .ask(.needsReview))
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionOrganize, caller: run(.agent, .bypass)), .allow)
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionOrganize, caller: run(.plan, .bypass)), .refuse(.planMode))
    }

    func testReadingQuestionsRunsAndAnsweringDependsOnWhose() {
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionQuestions, caller: run(.plan), answers: false), .allow,
                       "listing and reading is reading, also in Plan mode")
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionQuestions, caller: run()), .ask(.delegation),
                       "someone else's session waits for the user")
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionQuestions, caller: run(), ownTask: true), .allow,
                       "a task the caller delegated waits for the caller")
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionQuestions, caller: run(.agent, .bypass)), .allow)
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionQuestions, caller: run(.plan), ownTask: true), .refuse(.planMode))
        XCTAssertEqual(BridgePolicy.verdict(tool: .sessionQuestions, caller: run(), enabled: false, answers: false), .refuse(.disabled))
    }

    // MARK: Search

    func testSearchArguments() throws {
        let parsed = try BridgeSessionArguments.search(["query": " login bug ", "limit": "100", "session_id": id.uuidString]).get()
        XCTAssertEqual(parsed, .init(query: "login bug", sessionID: id, limit: BridgeSessionArguments.maxSearchLimit, includeArchived: false))
        XCTAssertEqual(try BridgeSessionArguments.search(["query": "x", "include_archived": true]).get().limit,
                       BridgeSessionArguments.defaultSearchLimit)
        XCTAssertThrowsError(try BridgeSessionArguments.search([:]).get())
        XCTAssertThrowsError(try BridgeSessionArguments.search(["query": "x", "session_id": "nope"]).get())
        XCTAssertThrowsError(try BridgeSessionArguments.search(["query": String(repeating: "a", count: 501)]).get())
    }

    func testMatchesReadAsExcerpts() {
        let asked = RunEvent(kind: .user, text: "Please fix the login bug on mobile")
        let answer = RunEvent(kind: .assistant, text: String(repeating: "x", count: 200) + " the LOGIN screen\nnow works")
        let events = [asked, answer]
        let result = TimelineSearch.search(events, query: "login")
        let text = BridgeSessionArguments.renderMatches(sessionLine: "abc · Fix", events: events, result: result)
        XCTAssertTrue(text.hasPrefix("abc · Fix · 2 matches"))
        XCTAssertTrue(text.contains("[user] Please fix the login bug on mobile"))
        XCTAssertTrue(text.contains("[agent] …"), "a long text is cut around the match")
        XCTAssertTrue(text.contains("LOGIN screen now works"), "on one line")
    }

    func testExcerptKeepsSecretsOut() {
        let secret = BridgeSecret.envelope(name: "KEY", value: "sk-123")
        let event = RunEvent(kind: .tool, text: "env", output: "token " + secret + " done")
        let result = TimelineSearch.search([event], query: "token")
        XCTAssertFalse(BridgeSessionArguments.renderMatches(sessionLine: "s", events: [event], result: result).contains("sk-123"))
    }

    // MARK: Organize

    func testOrganizeArguments() throws {
        let snooze = try BridgeSessionArguments.organize(["session_id": id.uuidString, "action": "snooze", "until": "Evening"]).get()
        XCTAssertEqual(snooze, .init(sessionID: id, action: .snooze, snooze: .evening))
        XCTAssertEqual(try BridgeSessionArguments.organize(["session_id": id.uuidString, "action": "snooze"]).get().snooze, .hour)
        XCTAssertEqual(try BridgeSessionArguments.organize(["session_id": id.uuidString, "action": "mark_unread"]).get().action, .markUnread)
        XCTAssertNil(try BridgeSessionArguments.organize(["session_id": id.uuidString, "action": "pin"]).get().snooze)
        XCTAssertThrowsError(try BridgeSessionArguments.organize(["session_id": id.uuidString, "action": "delete"]).get())
        XCTAssertThrowsError(try BridgeSessionArguments.organize(["session_id": id.uuidString, "action": "snooze", "until": "never"]).get())
        XCTAssertThrowsError(try BridgeSessionArguments.organize(["action": "pin"]).get())
    }

    // MARK: Questions

    private let questions = [
        RunQuestion(id: "q1", header: "Stack", question: "Which database?",
                    options: [RunQuestionOption(label: "Postgres", description: "Relational"), RunQuestionOption(label: "SQLite", description: "")],
                    multiSelect: false, allowsOther: false),
        RunQuestion(id: "q2", header: "", question: "Which platforms?",
                    options: [RunQuestionOption(label: "macOS", description: ""), RunQuestionOption(label: "iOS", description: "")],
                    multiSelect: true, allowsOther: true),
    ]

    func testQuestionArguments() throws {
        XCTAssertEqual(try BridgeSessionArguments.questions([:]).get().action, .list)
        let answer = try BridgeSessionArguments.questions([
            "action": "answer", "session_id": id.uuidString, "question_id": "codexq-1",
            "answers": ["q1": "postgres", "q2": ["macOS", "Linux"]],
        ]).get()
        XCTAssertEqual(answer.answers, ["q1": ["postgres"], "q2": ["macOS", "Linux"]])
        XCTAssertThrowsError(try BridgeSessionArguments.questions(["action": "read", "session_id": id.uuidString]).get(),
                             "read needs the question id")
        XCTAssertThrowsError(try BridgeSessionArguments.questions(["action": "answer", "session_id": id.uuidString,
                                                                   "question_id": "q"]).get(), "answer needs answers")
        XCTAssertThrowsError(try BridgeSessionArguments.questions(["action": "approve"]).get())
    }

    func testAnswersAreCheckedAgainstTheQuestion() throws {
        let fine = try BridgeSessionArguments.validate(["q1": ["postgres"], "q2": ["macOS", "Linux"]], for: questions).get()
        XCTAssertEqual(fine, ["q1": ["Postgres"], "q2": ["macOS", "Linux"]], "labels as the question spells them; own text where allowed")
        XCTAssertThrowsError(try BridgeSessionArguments.validate(["q1": ["MySQL"], "q2": ["iOS"]], for: questions).get(),
                             "q1 takes only its options")
        XCTAssertThrowsError(try BridgeSessionArguments.validate(["q1": ["Postgres", "SQLite"], "q2": ["iOS"]], for: questions).get(),
                             "a single choice takes one answer")
        XCTAssertThrowsError(try BridgeSessionArguments.validate(["q1": ["Postgres"]], for: questions).get(), "every question answered")
        XCTAssertThrowsError(try BridgeSessionArguments.validate(["q1": ["Postgres"], "q2": ["iOS"], "q9": ["x"]], for: questions).get())
    }

    func testAQuestionReadsWithItsOptions() {
        let text = BridgeSessionArguments.render(questionID: "codexq-7", questions: questions,
                                                 asked: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(text.hasPrefix("Question codexq-7 · waiting 5 min"))
        XCTAssertTrue(text.contains("- q1 (Stack): Which database?"))
        XCTAssertTrue(text.contains("    • Postgres — Relational"))
        XCTAssertTrue(text.contains("- q2: Which platforms? [several answers allowed] [own text allowed]"))
    }

    func testTheToolsAreListed() {
        for tool in [BridgeTool.sessionSearch, .sessionOrganize, .sessionQuestions] {
            XCTAssertEqual(BridgeTool.named("mcp__nook__" + tool.rawValue), tool)
            XCTAssertTrue(BridgeLaunch.instructions.contains(tool.rawValue), tool.rawValue)
        }
    }
}
