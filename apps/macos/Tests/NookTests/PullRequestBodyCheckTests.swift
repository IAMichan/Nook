import XCTest

final class PullRequestBodyCheckTests: XCTestCase {
    /// Nook's own template, shortened: the issue section's comment says "None" may stand in for an issue.
    private let template = """
    ## Summary

    ## Related issues

    <!-- List every issue this pull request resolves, one per line, as `Closes #123`. Write "None" if no issue matches. -->

    ## Why

    ## Testing

    <!-- Say what you ran. -->

    - [ ] Build succeeds
    """

    private func body(related: String = "None", extra: String = "") -> String {
        "## Summary\n- Names release runs.\n\n## Related issues\n\(related)\n\n## Why\nThe runs looked unrelated.\n\n## Testing\n- actionlint passes.\n" + extra
    }

    func testABodyThatFollowsTheTemplatePasses() {
        XCTAssertEqual(PullRequestBodyCheck.problems(body: body(), template: template), [])
        XCTAssertEqual(PullRequestBodyCheck.problems(body: body(related: "Closes #12\nPart of IAMichan/Nook#40"), template: template), [])
        XCTAssertEqual(PullRequestBodyCheck.problems(body: body(related: "- None."), template: template), [])
    }

    /// The description of #1556: "None" with an explanation behind it on the same line fails the repository's check.
    func testNoneMustStandOnItsOwnLine() {
        let problems = PullRequestBodyCheck.problems(body: body(related: "None (follow-up to PR #1555)."), template: template)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("`## Related issues`"))
        XCTAssertEqual(PullRequestBodyCheck.problems(body: body(related: "Follow-up to #1555."), template: template).count, 1)
    }

    func testMissingEmptyAndReorderedSectionsAreReported() {
        let missing = "## Summary\n- x\n\n## Related issues\nNone\n\n## Testing\n- ran it\n"
        XCTAssertEqual(PullRequestBodyCheck.problems(body: missing, template: template), ["Missing section `## Why`."])

        let empty = body().replacingOccurrences(of: "The runs looked unrelated.", with: "<!-- todo -->")
        XCTAssertEqual(PullRequestBodyCheck.problems(body: empty, template: template), ["Section `## Why` is empty."])

        // A section of its own is not the template's business (a review bot appends "## Summary by CodeRabbit").
        XCTAssertEqual(PullRequestBodyCheck.problems(body: body(extra: "\n## Summary by CodeRabbit\n- a\n"), template: template), [])

        let reordered = "## Why\nx\n\n## Summary\n- x\n\n## Related issues\nNone\n\n## Testing\n- ran it\n"
        XCTAssertEqual(PullRequestBodyCheck.problems(body: reordered, template: template).count, 1)
    }

    /// Only what the template states is asked: without "None" in its issue section any text goes there, and a template
    /// without headings asks nothing.
    func testOnlyTheTemplatesOwnRulesApply() {
        let plain = "## Summary\n\n## Related issues\n\n## Testing\n"
        let text = "## Summary\nx\n\n## Related issues\nFollow-up to #1555.\n\n## Testing\nran it\n"
        XCTAssertEqual(PullRequestBodyCheck.problems(body: text, template: plain), [])
        XCTAssertEqual(PullRequestBodyCheck.problems(body: "", template: "Describe your change."), [])
    }

    func testASectionWithOnlySubsectionsIsFilledIn() {
        let nested = body().replacingOccurrences(of: "The runs looked unrelated.", with: "### Before\nRuns looked unrelated.")
        XCTAssertEqual(PullRequestBodyCheck.problems(body: nested, template: template), [])
    }

    func testHeadingsInCodeBlocksAreNotSections() {
        let fenced = body(extra: "\n```\n## Changes\n```\n")
        XCTAssertEqual(PullRequestBodyCheck.problems(body: fenced, template: template), [])
    }

    func testTheRefusalNamesTheFixesAndTheTemplate() {
        let text = PullRequestBodyCheck.refusal(["Missing section `## Why`."], template: template)
        XCTAssertTrue(text.contains("was not opened"))
        XCTAssertTrue(text.contains("- Missing section `## Why`."))
        XCTAssertTrue(text.contains("## Related issues"))
    }
}
