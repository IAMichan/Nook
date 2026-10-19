import XCTest
#if canImport(NookCore)
@testable import NookCore
#endif

/// Mouse and keyboard control: which steps are accepted, which apps and shortcuts are never used, and how an element the
/// brain names is found again in the window.
final class UIControlTests: XCTestCase {
    // MARK: Steps

    private func steps(_ list: [[String: Any]]) -> [UIControl.Step] { UIControl.steps(list) }
    private func problems(_ app: String, _ list: [[String: Any]]) -> [String] { UIControl.problems(app: app, steps: list) }

    func testStepsAreReadFromTheProposal() {
        let parsed = steps([
            ["action": "click", "element": "Bluetooth", "role": "Switch"],
            ["action": "type", "text": "night", "replace": true],
            ["action": "key", "keys": "cmd+f"],
            ["action": "scroll", "direction": "down", "amount": 5],
            ["action": "double-click", "x": 100, "y": "200,5"],
            ["action": "teleport"]
        ])
        XCTAssertEqual(parsed.map(\.action), [.click, .type, .key, .scroll, .doubleClick], "an unknown action is dropped")
        XCTAssertEqual(parsed[0].role, "switch")
        XCTAssertTrue(parsed[1].replace)
        XCTAssertEqual(parsed[3].amount, 5)
        XCTAssertEqual(parsed[4].y, 200.5)
    }

    func testStepsSentAsAJSONString() {
        let steps = UIControl.steps(#"[{"action":"click","element":"OK"}]"#)
        XCTAssertEqual(steps.first?.element, "OK")
    }

    func testAGoodProposalHasNoProblems() {
        let problems = problems("System Settings", [
            ["action": "open", "url": "x-apple.systempreferences:com.apple.Displays-Settings.extension"],
            ["action": "click", "element": "Night Shift…"],
            ["action": "wait", "seconds": 1]
        ])
        XCTAssertEqual(problems, [])
    }

    func testProblemsAreNamedPerStep() {
        let problems = problems("Safari", [
            ["action": "click"],
            ["action": "type"],
            ["action": "key", "keys": "cmd+banana"],
            ["action": "scroll", "direction": "sideways"],
            ["action": "click", "x": 10],
            ["action": "open", "url": "https://example.com"],
            ["action": "wait", "seconds": 60],
            ["action": "fly"]
        ])
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 1:") && $0.contains("element") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 2:") && $0.contains("text") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 3:") && $0.contains("unknown key") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 4:") && $0.contains("direction") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 5:") && $0.contains("both x and y") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 6:") && $0.contains("System Settings") })
        XCTAssertTrue(problems.contains { $0.hasPrefix("Step 7:") && $0.contains("wait") })
        XCTAssertTrue(problems.contains { $0.contains("no valid action") })
    }

    func testEmptyAndTooLongProposals() {
        XCTAssertTrue(problems("Finder", []).contains("There are no steps."))
        XCTAssertTrue(problems("", [["action": "key", "keys": "return"]]).contains("The app is missing."))
        let many = Array(repeating: ["action": "key", "keys": "down"] as [String: Any], count: UIControl.maxSteps + 1)
        XCTAssertTrue(problems("Finder", many).contains { $0.contains("At most") })
        let long = String(repeating: "a", count: UIControl.maxText + 1)
        XCTAssertFalse(problems("Notes", [["action": "type", "text": long]]).isEmpty)
    }

    func testTheGateChecksControlSteps() {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["app": ["type": "string"], "steps": ["type": "array"]],
            "required": ["app", "steps"]
        ]
        let bad = ActionGate.problems(tool: "control_ui", input: ["app": "Terminal", "steps": [["action": "type", "text": "rm -rf ~"]]],
                                      schema: schema, parseDate: { _ in nil })
        XCTAssertTrue(bad.contains { $0.contains("does not control Terminal") })
        let good = ActionGate.problems(tool: "control_ui", input: ["app": "System Settings", "steps": [["action": "click", "element": "Bluetooth"]]],
                                       schema: schema, parseDate: { _ in nil })
        XCTAssertEqual(good, [])
        XCTAssertTrue(ActionGate.repeatable.contains("control_ui"), "the same switch may be flipped twice in a day")
    }

    // MARK: Apps and shortcuts that are off limits

    func testBlockedApps() {
        XCTAssertTrue(UIControl.isBlocked(app: "Terminal", bundleID: nil))
        XCTAssertTrue(UIControl.isBlocked(app: "Sleutelhangertoegang", bundleID: nil))
        XCTAssertTrue(UIControl.isBlocked(app: "Whatever", bundleID: "com.1password.1password"))
        XCTAssertTrue(UIControl.isBlocked(app: "Nook", bundleID: "nl.imdigital.nook"), "Nook never clicks its own Run button")
        XCTAssertTrue(UIControl.isBlocked(app: "iTerm.app", bundleID: nil))
        XCTAssertFalse(UIControl.isBlocked(app: "System Settings", bundleID: "com.apple.systempreferences"))
        XCTAssertFalse(UIControl.isBlocked(app: "Safari", bundleID: "com.apple.Safari"))
    }

    func testKeys() {
        XCTAssertEqual(UIControl.parseKeys("cmd+shift+n"), UIControl.KeyCombo(modifiers: [.command, .shift], key: "n", code: 45))
        XCTAssertEqual(UIControl.parseKeys("Command-F")?.modifiers, [.command])
        XCTAssertEqual(UIControl.parseKeys("⌘,")?.key, ",")
        XCTAssertEqual(UIControl.parseKeys("Return")?.code, 36)
        XCTAssertEqual(UIControl.parseKeys("arrow down")?.code, 125)
        XCTAssertEqual(UIControl.parseKeys("page down")?.code, 121)
        XCTAssertEqual(UIControl.parseKeys("cmd+-")?.key, "-")
        XCTAssertEqual(UIControl.parseKeys("cmd++")?.key, "=")
        XCTAssertNil(UIControl.parseKeys("hyper+x"))
        XCTAssertNil(UIControl.parseKeys(""))
    }

    func testShortcutsThatLeaveTheAppAreRefused() {
        for keys in ["ctrl+cmd+q", "cmd+shift+q", "cmd+option+escape", "cmd+space", "cmd+tab", "ctrl+right"] {
            XCTAssertNotNil(UIControl.parseKeys(keys).flatMap(UIControl.forbidden), keys)
        }
        for keys in ["cmd+f", "return", "tab", "cmd+a", "escape", "space"] {
            XCTAssertNil(UIControl.parseKeys(keys).flatMap(UIControl.forbidden), keys)
        }
    }

    // MARK: Finding elements

    private func element(_ role: String, _ label: String, x: Double, y: Double) -> UIControl.Element {
        UIControl.Element(role: role, label: label, value: nil, x: x, y: y, width: 40, height: 20)
    }

    func testAnExactLabelWins() {
        let elements = [
            element("row", "Bluetooth settings", x: 0, y: 0),
            element("switch", "Bluetooth", x: 300, y: 100)
        ]
        XCTAssertEqual(try? UIControl.match("bluetooth", role: nil, index: nil, in: elements).get().role, "switch")
        XCTAssertEqual(try? UIControl.match("Bluetooth sett", role: nil, index: nil, in: elements).get().role, "row", "then a label that starts with it")
        XCTAssertEqual(try? UIControl.match("“Bluetooth”", role: nil, index: nil, in: elements).get().role, "switch", "quotes around the label are ignored")
    }

    func testRepeatedLabelsNeedARoleOrIndex() {
        let elements = [
            element("button", "Add", x: 10, y: 300),
            element("button", "Add", x: 10, y: 100),
            element("popup", "Add", x: 200, y: 50)
        ]
        XCTAssertEqual(UIControl.match("Add", role: nil, index: nil, in: elements), .failure(.ambiguous("Add", 3)))
        XCTAssertEqual(try? UIControl.match("Add", role: "popup", index: nil, in: elements).get().x, 200)
        XCTAssertEqual(try? UIControl.match("Add", role: "button", index: 1, in: elements).get().y, 100, "index counts from the top")
        XCTAssertEqual(UIControl.match("Add", role: "button", index: 5, in: elements), .failure(.notFound("Add")))
        XCTAssertEqual(UIControl.match("Remove", role: nil, index: nil, in: elements), .failure(.notFound("Remove")))
    }

    func testAControlWinsOverItsOwnLabelText() {
        let elements = [
            element("text", "Dark", x: 100, y: 100),
            element("radio", "Dark", x: 100, y: 140)
        ]
        XCTAssertEqual(try? UIControl.match("Dark", role: nil, index: nil, in: elements).get().role, "radio")
        XCTAssertEqual(try? UIControl.match("Dark", role: "text", index: nil, in: elements).get().role, "text")
    }

    func testRolesHaveShortNames() {
        XCTAssertEqual(UIControl.role("AXCheckBox", subrole: "AXSwitch"), "switch")
        XCTAssertEqual(UIControl.role("AXTextField", subrole: "AXSecureTextField"), "password")
        XCTAssertEqual(UIControl.role("AXPopUpButton", subrole: nil), "popup")
        XCTAssertEqual(UIControl.role("AXSomethingNew", subrole: nil), "somethingnew")
        XCTAssertEqual(UIControl.stateText(role: "switch", value: NSNumber(value: 1)), "on")
        XCTAssertEqual(UIControl.stateText(role: "checkbox", value: NSNumber(value: 0)), "off")
    }

    func testTheWindowIsDescribedWithoutPasswords() {
        var secret = element("password", "Password", x: 0, y: 0)
        secret.secure = true
        secret.value = "hunter2"
        var toggle = element("switch", "Night Shift", x: 100, y: 100)
        toggle.value = "on"
        let text = UIControl.describe(app: "System Settings", window: "Displays", elements: [secret, toggle])
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertTrue(text.contains("switch \"Night Shift\" [on] @ 120,110"))
        XCTAssertTrue(text.contains("window \"Displays\""))
    }

    func testContinuationRounds() {
        XCTAssertEqual(UIControl.rounds(in: ["Zet Night Shift aan", "Ga verder", "Ga verder"], marker: "Ga verder"), 2)
        XCTAssertEqual(UIControl.rounds(in: ["Ga verder", "Zet Bluetooth uit"], marker: "Ga verder"), 0)
    }
}
