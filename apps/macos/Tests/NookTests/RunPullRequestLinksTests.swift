#if os(macOS)
import XCTest

/// `RunPullRequestLinks.created` remembers the link before a session's current turn, so the end of a turn reads that turn
/// instead of the whole conversation again. It must answer as reading everything does.
final class RunPullRequestLinksTests: XCTestCase {
    /// What the end of a turn found before the memo: the turn's last link, unless the conversation had it before.
    private func reference(_ all: [RunEvent]) -> URL? {
        guard let start = all.lastIndex(where: { $0.kind == .user }),
              let made = RunPullRequestLinks.last(in: Array(all[start...])),
              made != RunPullRequestLinks.last(in: Array(all[..<start])) else { return nil }
        return made
    }

    private func link(_ n: Int) -> String { "https://github.com/acme/app/pull/\(n)" }

    func testFindsTheLinkATurnBroughtAndNotOneFromBefore() {
        var memo: RunPullRequestLinks.BeforeTurn?
        var events = [RunEvent(kind: .user, text: "open a PR"), RunEvent(kind: .assistant, text: "Opened \(link(1))"),
                      RunEvent(kind: .result, text: "")]
        XCTAssertEqual(RunPullRequestLinks.created(in: events, before: &memo), URL(string: link(1)))
        // The next turn repeats the same link: nothing new.
        events += [RunEvent(kind: .user, text: "status?"), RunEvent(kind: .assistant, text: "Still \(link(1))"),
                   RunEvent(kind: .result, text: "")]
        XCTAssertNil(RunPullRequestLinks.created(in: events, before: &memo))
        // A turn without a link, then one with a new link.
        events += [RunEvent(kind: .user, text: "thanks"), RunEvent(kind: .assistant, text: "ok"), RunEvent(kind: .result, text: "")]
        XCTAssertNil(RunPullRequestLinks.created(in: events, before: &memo))
        events += [RunEvent(kind: .user, text: "another"), RunEvent(kind: .assistant, text: "See \(link(2))"),
                   RunEvent(kind: .result, text: "")]
        XCTAssertEqual(RunPullRequestLinks.created(in: events, before: &memo), URL(string: link(2)))
        // No user event at all: nothing.
        var none: RunPullRequestLinks.BeforeTurn?
        XCTAssertNil(RunPullRequestLinks.created(in: [RunEvent(kind: .assistant, text: link(3))], before: &none))
    }

    /// A script whose last line runs `gh pr create`: the event's text is cut short and its detail is the input as JSON,
    /// where that line starts after a written-out "\n". The link it printed is still the pull request it made.
    func testFindsAPullRequestMadeOnALaterLineOfAScript() {
        let detail = #"{\n  "command" : "cd ~\/repo && git push -q -u origin HEAD\ngh pr create --repo acme\/app --base main --title \"Add logo\" --body-file \/tmp\/pr.md 2>&1 | tail -1"\n}"#
        let tool = RunEvent(kind: .tool, text: "Bash · cd ~/repo && git push -q -u origin HEAD…", tool: "Bash",
                            detail: detail, output: "\(link(4149))\nShell cwd was reset to /repo", state: .done)
        var memo: RunPullRequestLinks.BeforeTurn?
        let events = [RunEvent(kind: .user, text: "make a new PR"), tool,
                      RunEvent(kind: .assistant, text: "The new PR is open: **acme/app#4149**."), RunEvent(kind: .result, text: "")]
        XCTAssertEqual(RunPullRequestLinks.created(in: events, before: &memo), URL(string: link(4149)))
        // A command that only reads a file named for pull requests still does not count.
        let reading = RunEvent(kind: .tool, text: "Bash · cat notes.md", tool: "Bash",
                               detail: #"{\n  "command" : "cd ~\/repo\ncat docs\/gh-pr-create.md"\n}"#, output: link(5))
        XCTAssertNil(RunPullRequestLinks.pullRequest(in: reading))
    }

    func testMatchesReadingTheWholeConversation() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            var events: [RunEvent] = []
            var memo: RunPullRequestLinks.BeforeTurn?
            for _ in 0..<Int.random(in: 1...12, using: &generator) {
                events.append(RunEvent(kind: .user, text: "go"))
                for _ in 0..<Int.random(in: 0...4, using: &generator) {
                    let roll = Int.random(in: 0..<6, using: &generator)
                    let text = roll < 2 ? "Made \(link(Int.random(in: 1...3, using: &generator)))" : "working"
                    events.append(RunEvent(kind: .assistant, text: text))
                }
                // Now and then the last event of an earlier turn grows after it was read (a streamed answer).
                if Int.random(in: 0..<5, using: &generator) == 0, let index = events.indices.dropLast().last,
                   events[index].kind == .assistant {
                    events[index].text += " \(link(Int.random(in: 1...3, using: &generator)))"
                }
                // Now and then a rollback takes the end of the conversation away.
                if Int.random(in: 0..<8, using: &generator) == 0, events.count > 2 {
                    events.removeLast(Int.random(in: 1..<events.count, using: &generator))
                    events.append(RunEvent(kind: .user, text: "again"))
                }
                events.append(RunEvent(kind: .result, text: ""))
                XCTAssertEqual(RunPullRequestLinks.created(in: events, before: &memo), reference(events))
            }
        }
    }
}
#endif
