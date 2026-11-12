import XCTest

/// Claude Code's AskUserQuestion option previews: read, shown in the code font, sent back as `annotations`, and passed
/// to the phone. (The hook path's `AgentQuestionRequest` is not in the test target; it uses the same `QuestionPreview`.)
final class QuestionPreviewTests: XCTestCase {
    private let input: [String: Any] = [
        "questions": [[
            "question": "Which layout?",
            "header": "Layout",
            "multiSelect": false,
            "options": [
                ["label": "Sidebar", "description": "List on the left", "preview": "```\n+------+--------+\n| list | detail |  \n+------+--------+\n```"],
                ["label": "Tabs", "description": "One at a time"],
            ],
        ]],
    ]

    func testReadKeepsThePreviewTrimmed() {
        XCTAssertEqual(QuestionPreview.read(["label": "a", "preview": "  box\n"]), "box")
        XCTAssertEqual(QuestionPreview.read(["label": "a"]), "")
    }

    func testStreamQuestionsKeepThePreview() {
        let questions = ClaudeStreamParser.questions(from: JSONBox(input))
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(questions[0].options[0].preview.hasPrefix("```"))
        XCTAssertEqual(questions[0].options[1].preview, "")
    }

    func testDisplayDropsAWrappingFenceAndTrailingSpaces() {
        XCTAssertEqual(QuestionPreview.display("```\n+------+--------+\n| list | detail |  \n+------+--------+\n```"),
                       "+------+--------+\n| list | detail |\n+------+--------+")
        XCTAssertEqual(QuestionPreview.display("```swift\nlet a = 1\n```"), "let a = 1")
        // A fence inside the preview stays.
        XCTAssertEqual(QuestionPreview.display("Intro\n```\ncode\n```"), "Intro\n```\ncode\n```")
        XCTAssertEqual(QuestionPreview.display("  \n"), "")
    }

    func testAVeryLongPreviewIsCut() {
        let long = String(repeating: "x", count: QuestionPreview.characterLimit + 50)
        let read = QuestionPreview.read(["preview": long])
        XCTAssertEqual(read.count, QuestionPreview.characterLimit + 1)
        XCTAssertTrue(read.hasSuffix("…"))
        XCTAssertEqual(QuestionPreview.read(["preview": 3]), "")
    }

    func testAnnotationsCarryThePreviewOfTheChosenOption() throws {
        let options = [(label: "Sidebar", preview: "+--+"), (label: "Tabs", preview: "")]
        let chosen = QuestionPreview.annotations([(question: "Which layout?", options: options, chosen: ["Sidebar"])])
        XCTAssertEqual((chosen["Which layout?"] as? [String: String])?["preview"], "+--+")
        // No preview on the chosen option, your own answer, or several chosen: nothing to annotate.
        XCTAssertTrue(QuestionPreview.annotations([(question: "Which layout?", options: options, chosen: ["Tabs"])]).isEmpty)
        XCTAssertTrue(QuestionPreview.annotations([(question: "Which layout?", options: options, chosen: ["Mine"])]).isEmpty)
        XCTAssertTrue(QuestionPreview.annotations([(question: "Which layout?", options: options, chosen: ["Sidebar", "Tabs"])]).isEmpty)
    }

    func testStreamAnswerSendsAnnotations() throws {
        let box = JSONBox(input)
        let questions = ClaudeStreamParser.questions(from: box)
        let line = ClaudeStreamParser.questionAnswer(requestID: "r1", input: box, questions: questions, answers: ["q0": ["Sidebar"]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let response = try XCTUnwrap((object["response"] as? [String: Any])?["response"] as? [String: Any])
        let updated = try XCTUnwrap(response["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["answers"] as? [String: String])?["Which layout?"], "Sidebar")
        let annotations = try XCTUnwrap(updated["annotations"] as? [String: [String: String]])
        XCTAssertEqual(annotations["Which layout?"]?["preview"], questions[0].options[0].preview)

        let plain = ClaudeStreamParser.questionAnswer(requestID: "r2", input: box, questions: questions, answers: ["q0": ["Tabs"]])
        XCTAssertFalse(plain.contains("annotations"))
    }

    func testPhonePreviewsTravelOnlyWhenThereAreAny() throws {
        XCTAssertNil(SessionDigest.Item.previews(["", ""]))
        let long = String(repeating: "y", count: SessionDigest.Item.previewLimit + 10)
        let previews = try XCTUnwrap(SessionDigest.Item.previews(["a", "", long]))
        XCTAssertEqual(previews[0], "a")
        XCTAssertEqual(previews[1], "")
        XCTAssertEqual(previews[2].count, SessionDigest.Item.previewLimit + 1)

        // An item without previews encodes as before, so an older phone reads it the same.
        let item = SessionDigest.Item(id: "i", kind: .question, title: "t", detail: "", canAllow: true, options: ["a"])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(item), encoding: .utf8))
        XCTAssertFalse(json.contains("optionPreviews"))
        let decoded = try JSONDecoder().decode(SessionDigest.Item.self, from: Data(#"{"id":"i","kind":"question","title":"t","detail":"","canAllow":true,"options":["a"],"optionPreviews":["box"]}"#.utf8))
        XCTAssertEqual(decoded.optionPreviews, ["box"])
    }
}
