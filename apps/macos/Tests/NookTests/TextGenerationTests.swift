import XCTest

/// Titles, commit messages and pull requests written by a headless agent.
final class TextGenerationTests: XCTestCase {
    func testPrompts() {
        let title = TextGeneration.titlePrompt(message: "Fix de login op mobiel")
        XCTAssertTrue(title.hasSuffix("User message:\nFix de login op mobiel"))
        XCTAssertTrue(title.contains("3-8 words, fewer than 40 characters."))
        let commit = TextGeneration.commitPrompt(branch: nil, files: "M\ta.swift", patch: String(repeating: "x", count: 40_010))
        XCTAssertTrue(commit.contains("Branch: (detached)"))
        XCTAssertTrue(commit.contains("write subject and body in English"))
        XCTAssertTrue(commit.hasSuffix("\n\n[truncated]"), "a long patch is cut off with a marker")
        let pr = TextGeneration.pullRequestPrompt(base: "main", head: "feat", commits: "abc fix", stat: "1 file", patch: "+x", template: nil)
        XCTAssertTrue(pr.contains("'## Summary' and '## Testing'"))
        XCTAssertTrue(pr.contains("write title and body in English"))
        let templated = TextGeneration.pullRequestPrompt(base: "main", head: "feat", commits: "", stat: "", patch: "", template: "## Summary\n")
        XCTAssertTrue(templated.contains("Repository change request template:\n## Summary"))
    }

    func testCommands() {
        let claude = TextGeneration.claudeArguments(schema: TextGeneration.titleSchema)
        XCTAssertEqual(value(after: "--model", in: claude), "haiku")
        XCTAssertEqual(value(after: "--tools", in: claude), "", "no tools: it only answers")
        XCTAssertEqual(value(after: "--settings", in: claude), #"{"disableAllHooks":true}"#, "never shows up in the notch")
        XCTAssertTrue(value(after: "--json-schema", in: claude)?.contains("needsRefinement") == true)
        let codex = TextGeneration.codexArguments(schemaPath: "/t/s.json", outputPath: "/t/a.txt")
        XCTAssertEqual(codex.first, "exec")
        XCTAssertEqual(value(after: "-s", in: codex), "read-only")
        XCTAssertTrue(codex.contains("--ephemeral"))
        XCTAssertEqual(codex.last, "-", "the prompt goes on stdin")
    }

    func testAnswers() {
        XCTAssertEqual(TextGeneration.claudeAnswer(#"{"type":"result","result":"","structured_output":{"title":"Login op mobiel","needsRefinement":false}}"#)?["title"] as? String,
                       "Login op mobiel")
        XCTAssertEqual(TextGeneration.claudeAnswer(#"[{"type":"system"},{"type":"result","result":"```json\n{\"title\":\"X\"}\n```"}]"#)?["title"] as? String, "X")
        XCTAssertNil(TextGeneration.claudeAnswer("not json"))
    }

    func testCleanUp() {
        XCTAssertEqual(TextGeneration.title("  \"`Mobiele   login`\"\nextra"), "Mobiele login")
        XCTAssertEqual(TextGeneration.title(#"{"title":"Uit JSON"}"#), "Uit JSON")
        XCTAssertNil(TextGeneration.title("New thread"))
        XCTAssertNil(TextGeneration.title("  "))
        XCTAssertEqual(TextGeneration.title(String(repeating: "a", count: 130))?.count, 120)
        XCTAssertEqual(TextGeneration.commitSubject("Add login retry...\n\nbody"), "Add login retry")
        XCTAssertEqual(TextGeneration.commitSubject(""), "Update project files")
        XCTAssertEqual(TextGeneration.commitSubject(String(repeating: "b", count: 90)).count, 72)
        XCTAssertEqual(TextGeneration.pullRequestTitle("\n"), "Update project changes")
    }

    func testRunnerWithAFakeClaude() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("claude")
        // Reads the prompt from stdin and answers with the last word of it as the title.
        try """
        #!/bin/sh
        last=$(cat | tail -n 1)
        printf '{"type":"result","structured_output":{"title":"%s","needsRefinement":false}}\\n' "$last"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let answer = TextGenerationRunner.run(engine: .claude, executable: script.path, environment: [:], prompt: "regel een\nZoekfunctie",
                                              schema: TextGeneration.titleSchema, cwd: folder.path, timeout: 20)
        XCTAssertEqual(answer?["title"] as? String, "Zoekfunctie")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
