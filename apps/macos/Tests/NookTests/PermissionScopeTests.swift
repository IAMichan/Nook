import XCTest

final class PermissionScopeTests: XCTestCase {
    func testClaudeSuggestionNamesRuleAndReach() {
        let suggestions: [Any] = [[
            "type": "addRules", "behavior": "allow", "destination": "localSettings",
            "rules": [["toolName": "Bash", "ruleContent": "git status:*"], ["toolName": "Edit"]],
        ]]
        let rules = PermissionScope.rules(from: suggestions)
        XCTAssertEqual(rules, [PermissionScope.Rule(text: "Bash(git status:*)", reach: .project),
                               PermissionScope.Rule(text: "Edit", reach: .project)])
    }

    func testDestinationsMapToReach() {
        XCTAssertEqual(PermissionScope.reach(destination: "projectSettings"), .sharedProject)
        XCTAssertEqual(PermissionScope.reach(destination: "userSettings"), .user)
        XCTAssertEqual(PermissionScope.reach(destination: "session"), .session)
        XCTAssertEqual(PermissionScope.reach(destination: nil), .agentDecides)
    }

    func testCodexAndAcpOfferPlainWords() {
        XCTAssertEqual(PermissionScope.rules(from: ["session"]), [PermissionScope.Rule(text: "", reach: .session)])
        XCTAssertEqual(PermissionScope.rules(from: ["always"]), [PermissionScope.Rule(text: "", reach: .agentDecides)])
        XCTAssertTrue(PermissionScope.rules(from: nil).isEmpty)
    }

    func testGrantedRulesReadAndRevoke() throws {
        let json = Data(#"{"model":"x","permissions":{"allow":["Bash(ls:*)","Edit"],"deny":["Bash(rm:*)"]}}"#.utf8)
        let entries = GrantedRules.entries(json: json, reach: .project, file: "f")
        XCTAssertEqual(entries.map(\.rule), ["Bash(ls:*)", "Edit"])
        let revoked = try XCTUnwrap(GrantedRules.removing(rule: "Edit", from: json))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: revoked) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "x")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash(ls:*)"])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"])
        XCTAssertNil(GrantedRules.removing(rule: "Nope", from: json))
    }
}

final class PlanChecklistTests: XCTestCase {
    private let plan = """
    # Plan
    1. Add the model
       - fields
       - migration
    2. Wire the view
    3. Write tests

    ```
    - not a step
    ```
    """

    func testStepsAreTheListItemsOutsideCode() {
        let list = PlanChecklist(markdown: plan)
        XCTAssertEqual(list.steps.map(\.text), ["Add the model", "fields", "migration", "Wire the view", "Write tests"])
        XCTAssertTrue(list.isUseful)
    }

    func testLeavingOutAStepDropsItsSubSteps() {
        var list = PlanChecklist(markdown: plan)
        list.toggle(list.steps[0].id)
        XCTAssertFalse(list.text.contains("Add the model"))
        XCTAssertFalse(list.text.contains("migration"))
        XCTAssertTrue(list.text.contains("Wire the view"))
        XCTAssertEqual(list.keptCount, 2)
        list.toggle(list.steps[0].id)
        XCTAssertEqual(list.text, plan)
    }

    func testProgress() {
        XCTAssertEqual(PlanChecklist.progress(done: 1, total: 4), 0.25)
        XCTAssertEqual(PlanChecklist.progress(done: 9, total: 4), 1)
        XCTAssertEqual(PlanChecklist.progress(done: 1, total: 0), 0)
    }
}
