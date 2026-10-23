import XCTest

final class TurnDiffTests: XCTestCase {
    func testAnEditBecomesOneHunkWithContext() {
        let old = "a\nb\nc\nd\ne\nf\ng"
        let new = "a\nb\nc\nd\nE\nf\ng"
        XCTAssertEqual(EditPatch.hunk(old, new), "@@ -2,6 +2,6 @@\n b\n c\n d\n-e\n+E\n f\n g")
        XCTAssertEqual(EditPatch.hunk("same", "same"), "")
    }

    func testAWrittenFileIsAllAdded() {
        XCTAssertEqual(EditPatch.make(tool: "Write", input: ["content": "x\ny\n"]), "@@ -0,0 +1,2 @@\n+x\n+y")
        XCTAssertNil(EditPatch.make(tool: "Bash", input: ["command": "ls"]))
    }

    func testACodexPatchSplitsPerFile() {
        let patch = """
        *** Begin Patch
        *** Update File: src/a.ts
        @@
        -old
        +new
        *** Add File: src/b.ts
        +hello
        *** End Patch
        """
        let files = EditPatch.codexFiles(patch)
        XCTAssertEqual(files.map(\.path), ["src/a.ts", "src/b.ts"])
        XCTAssertEqual(files[1].patch, "@@ -0,0 +1,1 @@\n+hello")
        XCTAssertEqual(EditLines.of(patch: files[0].patch), EditLines(added: 1, removed: 1))
    }

    func testTurnsCollectTheirFilesAndTheCardGoesUnderTheLastAnswer() {
        let lines = [
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"Rename it"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/A.swift","old_string":"let a = 1","new_string":"let b = 1"}},{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/p/B.swift","content":"x\ny"}}]}}"#,
            #"{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"},{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"/p/A.swift","old_string":"x","new_string":"y"}}]}}"#,
            #"{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"role":"user","content":"Thanks"}}"#,
            #"{"type":"assistant","uuid":"a4","message":{"role":"assistant","content":[{"type":"text","text":"Sure."}]}}"#,
            #"{"type":"user","uuid":"u3","message":{"role":"user","content":"Now B"}}"#,
            #"{"type":"assistant","uuid":"a5","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Edit","input":{"file_path":"/p/B.swift","old_string":"y","new_string":"z"}}]}}"#
        ]
        let messages = AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8))
        let turns = TurnDiff.collect(messages)
        XCTAssertEqual(turns.map(\.id), ["u1", "u3"], "a turn that changed nothing has no card")
        XCTAssertEqual(turns.map(\.number), [1, 3])
        XCTAssertEqual(turns[0].answerID, "a3-0")
        XCTAssertEqual(turns[0].files.map(\.path), ["/p/A.swift", "/p/B.swift"])
        XCTAssertEqual(turns[0].files[0].patches.count, 2)
        XCTAssertEqual(turns[0].lines, EditLines(added: 4, removed: 2))
        XCTAssertTrue(turns[0].files[0].diff.hasPrefix("diff --git a/p/A.swift b/p/A.swift\n@@ -1,1 +1,1 @@\n-let a = 1\n+let b = 1"))

        let tree = turns[0].tree(relativeTo: "/p").flatten(expanded: [])
        XCTAssertEqual(tree.map(\.path), ["A.swift", "B.swift"])
        XCTAssertEqual(tree.last?.kind, .added)
        XCTAssertEqual(turns[0].file("B.swift", relativeTo: "/p")?.path, "/p/B.swift")
        XCTAssertEqual(turns[0].file("p/B.swift", relativeTo: nil)?.path, "/p/B.swift", "the tree drops the leading slash")
        let session = TurnDiff.session(turns)
        XCTAssertEqual(session.files.map(\.path), ["/p/A.swift", "/p/B.swift"])
        XCTAssertEqual(session.files[1].patches.count, 2)
        XCTAssertEqual(UnifiedDiff.rows(TurnDiff.diff(session.files)).filter { $0.kind == .file }.count, 2)
    }

    func testAMessageSentWhileWorkingIsMarked() {
        let line = #"{"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"Also this","commandMode":"prompt","origin":{"kind":"human"}}}"#
        XCTAssertEqual(AgentTranscript.jsonl(Data(line.utf8)).first?.queued, true)
    }

    func testASessionNookRunsGetsItsTurnsFromTheTimeline() {
        let t0 = Date(timeIntervalSince1970: 0)
        let edit = #"{"file_path":"/p/A.swift","old_string":"a","new_string":"b"}"#
        let events = [
            RunEvent(kind: .user, text: "Change A", date: t0),
            RunEvent(kind: .tool, text: "Edit", tool: "Edit", detail: edit, state: .done, date: t0.addingTimeInterval(1)),
            RunEvent(kind: .fileChange, text: "", tool: "modified", detail: "/p/B.swift", date: t0.addingTimeInterval(2)),
            RunEvent(kind: .assistant, text: "Done", date: t0.addingTimeInterval(3)),
            RunEvent(kind: .result, text: "", date: t0.addingTimeInterval(4)),
            RunEvent(kind: .user, text: "Explain", date: t0.addingTimeInterval(5)),
            RunEvent(kind: .result, text: "", date: t0.addingTimeInterval(6)),
            RunEvent(kind: .user, text: "Still going", date: t0.addingTimeInterval(7)),
            RunEvent(kind: .tool, text: "Edit", tool: "Edit", detail: edit, state: .running, date: t0.addingTimeInterval(8)),
        ]
        let turns = TurnDiff.collect(events: events)
        XCTAssertEqual(turns.count, 1, "a turn without changes or still running has no card")
        XCTAssertEqual(turns[0].answerID, events[4].id.uuidString)
        XCTAssertEqual(turns[0].files.map(\.path), ["/p/A.swift", "/p/B.swift"])
        XCTAssertEqual(turns[0].files[1].patches, [])
        XCTAssertEqual(turns[0].start, t0)
        XCTAssertEqual(turns[0].counted(["B.swift": EditLines(added: 3, removed: 1)], relativeTo: "/p").files[1].lines,
                       EditLines(added: 3, removed: 1))
        XCTAssertEqual(TurnDiff.session(turns).end, t0.addingTimeInterval(4))
    }
}
