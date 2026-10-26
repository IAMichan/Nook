import XCTest

final class SyntaxTokenizerTests: XCTestCase {
    /// The tokens of a line as (kind, text) pairs, easy to read in a failure.
    private func tokens(_ line: String, _ language: SyntaxLanguage,
                        carry: SyntaxTokenizer.Carry = .none) -> [(SyntaxToken.Kind, String)] {
        let units = Array(line.utf16)
        return SyntaxTokenizer.tokenize(line, language: language, carry: carry).tokens.map {
            ($0.kind, String(decoding: units[$0.start..<$0.end], as: UTF16.self))
        }
    }

    private func assertTokens(_ line: String, _ language: SyntaxLanguage, _ expected: [(SyntaxToken.Kind, String)],
                              file: StaticString = #filePath, lineNumber: UInt = #line) {
        let actual = tokens(line, language)
        XCTAssertEqual(actual.map { "\($0.0.rawValue):\($0.1)" }, expected.map { "\($0.0.rawValue):\($0.1)" },
                       file: file, line: lineNumber)
    }

    func testDetectsLanguagesByFileName() {
        XCTAssertEqual(SyntaxLanguage.detect(path: "Sources/App.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage.detect(path: "web/src/page.TSX"), .typescript)
        XCTAssertEqual(SyntaxLanguage.detect(path: "a/b.mjs"), .typescript)
        XCTAssertEqual(SyntaxLanguage.detect(path: "x.py"), .python)
        XCTAssertEqual(SyntaxLanguage.detect(path: "main.rs"), .rust)
        XCTAssertEqual(SyntaxLanguage.detect(path: "main.go"), .go)
        XCTAssertEqual(SyntaxLanguage.detect(path: "package.json"), .json)
        XCTAssertEqual(SyntaxLanguage.detect(path: ".github/workflows/ci.yml"), .yaml)
        XCTAssertEqual(SyntaxLanguage.detect(path: "scripts/run.sh"), .shell)
        XCTAssertEqual(SyntaxLanguage.detect(path: "~/.zshrc"), .shell)
        XCTAssertEqual(SyntaxLanguage.detect(path: "style.scss"), .css)
        XCTAssertEqual(SyntaxLanguage.detect(path: "index.html"), .html)
        XCTAssertEqual(SyntaxLanguage.detect(path: "README.md"), .markdown)
        XCTAssertNil(SyntaxLanguage.detect(path: "Makefile"))
        XCTAssertNil(SyntaxLanguage.detect(path: "image.png"))
    }

    func testSwift() {
        assertTokens(#"@MainActor func load(_ id: Int) -> String { return "x\"y" } // done"#, .swift, [
            (.attribute, "@MainActor"), (.keyword, "func"), (.type, "Int"), (.type, "String"), (.keyword, "return"),
            (.string, #""x\"y""#), (.comment, "// done"),
        ])
        assertTokens("let n = 0x1F + 2.5e-3 ?? nil", .swift, [(.keyword, "let"), (.number, "0x1F"), (.number, "2.5e-3"), (.number, "nil")])
    }

    func testTypeScriptTemplatesAndComments() {
        assertTokens("export const x: Foo = `a ${b}` /* c */ + 1;", .typescript, [
            (.keyword, "export"), (.keyword, "const"), (.type, "Foo"), (.string, "`a ${b}`"), (.comment, "/* c */"), (.number, "1"),
        ])
        let open = SyntaxTokenizer.tokenize("const s = `line one", language: .typescript)
        XCTAssertEqual(open.carry, .string("`"))
        XCTAssertEqual(tokens("still` + done", .typescript, carry: open.carry).first?.1, "still`")
    }

    func testBlockCommentCarriesOverLines() {
        let first = SyntaxTokenizer.tokenize("int a; /* starts", language: .go)
        XCTAssertEqual(first.carry, .blockComment)
        let middle = SyntaxTokenizer.tokenize("still comment", language: .go, carry: first.carry)
        XCTAssertEqual(middle.carry, .blockComment)
        XCTAssertEqual(middle.tokens, [SyntaxToken(kind: .comment, start: 0, end: 13)])
        let last = SyntaxTokenizer.tokenize("ends */ return nil", language: .go, carry: .blockComment)
        XCTAssertEqual(last.carry, .none)
        XCTAssertEqual(tokens("ends */ return nil", .go, carry: .blockComment).map(\.1), ["ends */", "return", "nil"])
    }

    func testPythonTripleQuotesAndDecorators() {
        assertTokens("@app.route('/x')", .python, [(.attribute, "@app.route"), (.string, "'/x'")])
        assertTokens("def f(self): return None  # why", .python, [
            (.keyword, "def"), (.keyword, "self"), (.keyword, "return"), (.number, "None"), (.comment, "# why"),
        ])
        let doc = SyntaxTokenizer.tokenize(#"    """Docs"#, language: .python)
        XCTAssertEqual(doc.carry, .string(#"""""#))
        XCTAssertEqual(SyntaxTokenizer.tokenize(#"end""" + 1"#, language: .python, carry: doc.carry).carry, .none)
    }

    func testRust() {
        assertTokens("pub fn new() -> Self { Vec::new() }", .rust, [(.keyword, "pub"), (.keyword, "fn"), (.keyword, "Self"), (.type, "Vec")])
    }

    func testJSONKeysAndValues() {
        assertTokens(#"  "name": "nook", "count": -12, "ok": true, "none": null"#, .json, [
            (.property, #""name""#), (.string, #""nook""#), (.property, #""count""#), (.number, "-12"),
            (.property, #""ok""#), (.number, "true"), (.property, #""none""#), (.number, "null"),
        ])
    }

    func testYAML() {
        assertTokens("runs-on: ubuntu-latest # the runner", .yaml, [(.property, "runs-on"), (.comment, "# the runner")])
        assertTokens("  timeout: 30", .yaml, [(.property, "timeout"), (.number, "30")])
        assertTokens("url: a#b", .yaml, [(.property, "url")])
    }

    func testShell() {
        assertTokens(#"if [ -n "$HOME" ]; then echo ${#ARR} $1; fi # end"#, .shell, [
            (.keyword, "if"), (.string, #""$HOME""#), (.keyword, "then"), (.keyword, "echo"), (.property, "${#ARR}"),
            (.property, "$1"), (.keyword, "fi"), (.comment, "# end"),
        ])
    }

    func testCSS() {
        assertTokens("  background-color: #fff; /* x */", .css, [(.property, "background-color"), (.number, "#fff"), (.comment, "/* x */")])
        assertTokens("@media (max-width: 600px) {", .css, [(.attribute, "@media"), (.property, "max-width"), (.number, "600px")])
    }

    func testHTML() {
        assertTokens(#"<a href="/x" class='y'>Hi</a> <!-- note -->"#, .html, [
            (.tag, "<a"), (.property, "href"), (.string, #""/x""#), (.property, "class"), (.string, "'y'"), (.tag, ">"),
            (.tag, "</a"), (.tag, ">"), (.comment, "<!-- note -->"),
        ])
        let open = SyntaxTokenizer.tokenize(#"<div id="a""#, language: .html)
        XCTAssertEqual(open.carry, .tag)
        XCTAssertEqual(tokens(#"  data-x="1">"#, .html, carry: .tag).map(\.0), [.property, .string, .tag])
    }

    func testMarkdown() {
        assertTokens("## Install", .markdown, [(.keyword, "## Install")])
        assertTokens("- run `make` then [docs](https://x.dev)", .markdown, [(.keyword, "-"), (.string, "`make`"), (.property, "https://x.dev")])
        assertTokens("#hashtag", .markdown, [])
        let fence = SyntaxTokenizer.tokenize("```swift", language: .markdown)
        XCTAssertEqual(fence.carry, .fence)
        XCTAssertEqual(SyntaxTokenizer.tokenize("# not a heading", language: .markdown, carry: .fence).tokens, [])
        XCTAssertEqual(SyntaxTokenizer.tokenize("```", language: .markdown, carry: .fence).carry, .none)
    }

    func testNonASCIIOffsetsAreUTF16() {
        let line = #"let café = "é😀" // ü"#
        let result = SyntaxTokenizer.tokenize(line, language: .swift).tokens
        let units = Array(line.utf16)
        XCTAssertEqual(result.map { String(decoding: units[$0.start..<$0.end], as: UTF16.self) }, ["let", #""é😀""#, "// ü"])
    }

    // MARK: Diffs

    func testDiffTokensFollowEachFilesLanguage() {
        let diff = """
        diff --git a/a.swift b/a.swift
        @@ -1,2 +1,2 @@
        -let a = 1
        +var a = 2
        diff --git a/notes.txt b/notes.txt
        @@ -1 +1 @@
        -let it be
        +let it go
        """
        let rows = UnifiedDiff.rows(diff)
        let tokens = DiffSyntax.tokens(rows: rows, path: nil)
        let swiftRows = rows.indices.filter { rows[$0].text.hasPrefix("let a") || rows[$0].text.hasPrefix("var a") }
        XCTAssertEqual(swiftRows.count, 2)
        XCTAssertTrue(swiftRows.allSatisfy { tokens[$0] != nil })
        let textRows = rows.indices.filter { rows[$0].text.hasPrefix("let it") }
        XCTAssertTrue(textRows.allSatisfy { tokens[$0] == nil }, "an unknown language stays plain")
    }

    func testFirstPathAndSingleFileDiff() {
        XCTAssertEqual(DiffSyntax.firstPath(in: "diff --git a/x/y.py b/x/y.py\nindex 1..2\n"), "x/y.py")
        XCTAssertEqual(DiffSyntax.firstPath(in: "--- /dev/null\n+++ b/new.rs\n@@ -0,0 +1 @@\n+fn x() {}"), "new.rs")
        XCTAssertNil(DiffSyntax.firstPath(in: "@@ -1 +1 @@\n-a\n+b"))
        let rows = UnifiedDiff.rows("@@ -1 +1 @@\n-fn a() {}\n+fn b() {}")
        XCTAssertEqual(DiffSyntax.tokens(rows: rows, path: "lib.rs").count, 2)
    }

    func testSegmentsCoverTheLineAndSplitAtTheChange() {
        let tokens = [SyntaxToken(kind: .keyword, start: 0, end: 3), SyntaxToken(kind: .number, start: 8, end: 20)]
        let segments = DiffSyntax.segments(length: 10, tokens: tokens, changed: 2..<5)
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.last?.end, 10, "clipped to the line")
        for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertEqual(segments.map { [$0.start, $0.end] }, [[0, 2], [2, 3], [3, 5], [5, 8], [8, 10]])
        XCTAssertEqual(segments.map(\.changed), [false, true, true, false, false])
        XCTAssertEqual(segments.map(\.kind), [.keyword, .keyword, nil, nil, .number])
        XCTAssertEqual(DiffSyntax.segments(length: 0, tokens: tokens, changed: nil), [])
    }

    func testKeyAndBoundedCache() {
        XCTAssertEqual(DiffSyntax.Key(path: "a.swift", text: "x"), DiffSyntax.Key(path: "a.swift", text: "x"))
        XCTAssertNotEqual(DiffSyntax.Key(path: "a.swift", text: "x"), DiffSyntax.Key(path: "a.swift", text: "y"))
        XCTAssertNotEqual(DiffSyntax.Key(path: "a.swift", text: "x"), DiffSyntax.Key(path: "b.swift", text: "x"))
        let cache = BoundedCache<String, Int>(limit: 2)
        cache.set(1, for: "a")
        cache.set(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1, "reading makes it recent")
        cache.set(3, for: "c")
        XCTAssertNil(cache.value(for: "b"), "the least recently used goes first")
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.count, 2)
    }
}
