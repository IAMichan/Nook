import XCTest

/// Pictures the agent only looked at, shown as thumbnails under the step that read them (t3code 5b11efe5df).
final class ViewedImagesTests: XCTestCase {
    func testEveryAgentsReadOfAPictureCounts() {
        // Claude Code, Gemini CLI, Codex, OpenCode, Cursor, an ACP agent (with the location Nook put in), Pi.
        XCTAssertEqual(ViewedImages.paths(tool: "Read", input: ["file_path": "/r/shot.png"]), ["/r/shot.png"])
        XCTAssertEqual(ViewedImages.paths(tool: "read_file", input: ["absolute_path": "/r/a.JPG"]), ["/r/a.JPG"])
        XCTAssertEqual(ViewedImages.paths(tool: "view_image", input: ["path": "img/b.webp"]), ["img/b.webp"])
        XCTAssertEqual(ViewedImages.paths(tool: "read", input: ["filePath": "/r/c.png"]), ["/r/c.png"])
        XCTAssertEqual(ViewedImages.paths(tool: "read_file", input: ["target_file": "d.gif"]), ["d.gif"])
        XCTAssertEqual(ViewedImages.paths(tool: "read", input: ["locations": [["path": "/r/e.png"]]]), ["/r/e.png"])
        XCTAssertEqual(ViewedImages.paths(tool: "mcp__files__read_file", input: ["path": "/r/f.png"]), ["/r/f.png"])
        // read_many_files: every picture once, no patterns.
        XCTAssertEqual(ViewedImages.paths(tool: "read_many_files", input: ["paths": ["/r/a.png", "*.png", "/r/a.png", "/r/n.md"]]),
                       ["/r/a.png"])
    }

    func testOtherFilesAndToolsDoNot() {
        XCTAssertTrue(ViewedImages.paths(tool: "Read", input: ["file_path": "/r/app.swift"]).isEmpty)
        XCTAssertTrue(ViewedImages.paths(tool: "Write", input: ["file_path": "/r/out.png"]).isEmpty, "a picture it wrote is no picture it viewed")
        XCTAssertTrue(ViewedImages.paths(tool: "Bash", input: ["command": "open /r/out.png"]).isEmpty)
        XCTAssertTrue(ViewedImages.paths(tool: "Read", input: [:]).isEmpty)
    }

    func testAFailedCallShowsNothing() {
        let done = RunEvent(kind: .tool, text: "Read · shot.png", tool: "Read", detail: #"{"file_path":"/r/shot.png"}"#, state: .done)
        XCTAssertEqual(ViewedImages.paths(done), ["/r/shot.png"])
        var failed = done
        failed.state = .failed
        XCTAssertTrue(ViewedImages.paths(failed).isEmpty)
        XCTAssertTrue(ViewedImages.paths(RunEvent(kind: .assistant, text: "/r/shot.png")).isEmpty)
    }

    func testTranscriptSteps() {
        let step = AgentToolStep(id: "s", name: "Read", summary: "shot.png", state: .done, input: #"{"file_path":"/r/shot.png"}"#)
        XCTAssertEqual(ViewedImages.paths(step), ["/r/shot.png"])
        // Without its input kept, the file it read.
        XCTAssertEqual(ViewedImages.paths(AgentToolStep(id: "s", name: "Read", summary: "", state: .done, file: "/r/b.png")), ["/r/b.png"])
        XCTAssertTrue(ViewedImages.paths(AgentToolStep(id: "s", name: "Read", summary: "", state: .failed, file: "/r/b.png")).isEmpty)
    }

    func testCodexTranscriptViewImageOpensItsPicture() throws {
        let lines = [
            #"{"type":"response_item","payload":{"type":"function_call","name":"view_image","call_id":"v1","arguments":"{\"path\":\"/r/shot.png\"}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"v1","output":"ok"}}"#,
        ]
        let step = try XCTUnwrap(AgentTranscript.jsonl(Data(lines.joined(separator: "\n").utf8)).flatMap(\.steps).first)
        XCTAssertEqual(step.file, "/r/shot.png")
        XCTAssertEqual(ViewedImages.paths(step), ["/r/shot.png"])
    }

    func testResolvedPathsAreAbsoluteAndOnce() {
        XCTAssertEqual(ViewedImages.resolved(["img/a.png", "/abs/b.png", "./img/a.png"], in: "/repo"), ["/repo/img/a.png", "/abs/b.png"])
        XCTAssertEqual(ViewedImages.resolved(["img/a.png"], in: nil), [], "a relative path needs the session's folder")
        XCTAssertEqual(ViewedImages.resolved(["~/shot.png"], in: nil), [NSHomeDirectory() + "/shot.png"])
    }
}
