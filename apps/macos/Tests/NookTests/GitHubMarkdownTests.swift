import XCTest

final class GitHubMarkdownTests: XCTestCase {
    func testPlainMarkdownStaysAsItIs() {
        let text = "## Summary\n\n- **Fix** the `merge` bar\n- Add tests\n\n> [!NOTE]\n> Keep it"
        XCTAssertEqual(GitHubMarkdown.markdown(text), text)
    }

    func testCommentsAndDetailsBecomeMarkdown() {
        let text = """
        <!-- review-bot:marker -->
        Looks good.

        <details>
        <summary><b>Walkthrough</b></summary>

        The change adds &quot;merging&quot; &amp; tests.
        </details>
        """
        XCTAssertEqual(GitHubMarkdown.markdown(text), "Looks good.\n\n**Walkthrough**\n\nThe change adds \"merging\" & tests.")
    }

    func testInlineTagsLinksAndImages() {
        let text = #"<b>Bold</b>, <i>soft</i>, <code>x</code><br><sub>small</sub> <a href="https://example.com/a">docs</a> <img src="https://x/y.png" alt="badge">"#
        XCTAssertEqual(GitHubMarkdown.markdown(text), "**Bold**, *soft*, `x`\nsmall [docs](https://example.com/a) badge")
    }

    func testHeadingsAndRules() {
        XCTAssertEqual(GitHubMarkdown.markdown("<h3>Risks</h3>none<hr>"), "### Risks\n\nnone\n\n---")
    }

    func testCodeInAListItemStandsOnItsOwn() {
        let text = "- Use this:\n  ```suggestion\n  let a = 1\n    let b = 2\n  ```\n- Next"
        XCTAssertEqual(GitHubMarkdown.markdown(text), "- Use this:\n\n```suggestion\nlet a = 1\n  let b = 2\n```\n\n- Next")
    }

    func testCodeKeepsItsTags() {
        let text = "```html\n<b>x</b> &amp;\n\n\n```"
        XCTAssertEqual(GitHubMarkdown.markdown(text), "```html\n<b>x</b> &amp;\n\n\n```")
    }

    func testInlineCodeKeepsItsTags() {
        XCTAssertEqual(GitHubMarkdown.markdown("Wrap it in `<details>` &amp; <b>go</b>"), "Wrap it in `<details>` & **go**")
    }

    func testGenericsAreNotTags() {
        XCTAssertEqual(GitHubMarkdown.markdown("Returns Array<Int> when a < b"), "Returns Array<Int> when a < b")
    }

    func testDefinitionListsAndTagsWithAttributesBecomeMarkdown() {
        let text = """
        <details open>
        <summary><strong>Merge Risk:</strong> <strong>Low</strong> · up to <code>c4340</code></summary>
        <dl>
        <dd>

        - [ ] <strong title="Keep fixing">Autofix</strong> · on

        </dd>
        </dl>
        </details>
        """
        XCTAssertEqual(GitHubMarkdown.markdown(text), "**Merge Risk: Low · up to `c4340`**\n\n- [ ] **Autofix** · on")
    }

    func testSummaryBadgesKeepTheirAltText() {
        let text = #"<summary><strong>Checks: <sup><img src="https://x/p.svg" alt="Passed"></sup> 4</strong></summary>"#
        XCTAssertEqual(GitHubMarkdown.markdown(text), "**Checks: Passed 4**")
    }

    func testQuotedPlainParagraphsStayQuoted() {
        XCTAssertEqual(GitHubMarkdown.markdown("> One <b>two</b>\n>\n> Three"), "> One **two**\n>\n> Three")
    }

    func testBlocksInAQuoteMoveOutAfterItsFirstParagraph() {
        let text = """
        > [!NOTE]
        > Processing changes.
        > 
        > <details>
        > <summary><strong>Run configuration</strong></summary>
        > <dl>
        > <dd>
        > 
        > - **Branch**: main
        > 
        > </dd>
        > </dl>
        > </details>
        > 
        > ```ascii
        > +---+
        > | x |
        > ```

        Walkthrough
        """
        XCTAssertEqual(GitHubMarkdown.markdown(text), """
        > [!NOTE]
        > Processing changes.

        **Run configuration**

        - **Branch**: main

        ```ascii
        +---+
        | x |
        ```

        Walkthrough
        """)
    }
}
