import XCTest

final class SpawnedSessionsTests: XCTestCase {
    func testTaskKeysComeFromSpawnTaskCalls() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Done."],
            ["type": "tool_use", "name": "mcp__ccd_session__spawn_task", "input": ["title": "Link Telegram", "prompt": "Link  Telegram\nthrough the helper."]],
            ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]],
        ]
        XCTAssertEqual(SpawnedSessions.taskKeys(in: content), ["Link Telegram through the helper."])
    }

    func testChildFindsTheSessionThatSpawnedIt() {
        let parents = SpawnedSessions.parents(
            firstPrompts: ["parent": "Make chats work", "child": "Link Telegram through the helper.", "other": "Fix the build"],
            tasks: ["parent": ["Link Telegram through the helper."]])
        XCTAssertEqual(parents, ["child": "parent"])
    }

    func testAPromptTheAppAddedToStillMatches() {
        let parents = SpawnedSessions.parents(
            firstPrompts: ["child": "Context from the earlier session. Link Telegram through the helper."],
            tasks: ["parent": ["Link Telegram through the helper."]])
        XCTAssertEqual(parents["child"], "parent")
    }
}
