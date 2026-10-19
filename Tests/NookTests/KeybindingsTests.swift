import XCTest

final class KeybindingsTests: XCTestCase {
    private func chord(_ s: String) -> KeyChord { KeyChord.parse(s)! }
    private func rule(_ key: String, _ command: String, _ when: String? = nil) -> KeybindingRule {
        KeybindingRule(key: key, command: command, when: when)
    }

    // MARK: Chords

    func testParseAndFormat() {
        XCTAssertEqual(chord("mod+shift+k").formatted, "mod+shift+k")
        XCTAssertEqual(chord("shift+mod+K").formatted, "mod+shift+k", "canonical order and case")
        XCTAssertEqual(chord("alt+up"), chord("option+arrowup"))
        XCTAssertEqual(chord("mod+enter"), chord("mod+return"))
        XCTAssertEqual(chord("mod++").key, "+")
        XCTAssertEqual(chord("mod+=").key, "=")
        XCTAssertEqual(chord("mod+shift+[").key, "[")
        XCTAssertEqual(chord("f5").key, "f5")
        XCTAssertEqual(chord("mod+shift+enter").modifiers, [.mod, .shift])
    }

    func testParseRejectsGarbage() {
        for bad in ["", "mod+", "+shift", "hyper+k", "mod+nonsense", "mod+shift", "mod+f99", "k+k"] {
            XCTAssertNil(KeyChord.parse(bad), bad)
        }
    }

    func testModIsCommandOnMac() {
        XCTAssertEqual(chord("mod+k").resolved, chord("cmd+k"))
        XCTAssertEqual(chord("meta+k").resolved, chord("cmd+k"))
        XCTAssertEqual(chord("ctrl+k").resolved, chord("ctrl+k"))
        XCTAssertEqual(chord("mod+shift+k").symbols, "⇧⌘K")
        XCTAssertEqual(chord("alt+up").symbols, "⌥↑")
    }

    // MARK: When

    func testWhenEvaluation() {
        let ctx = ["a": true, "b": false, "c": true]
        func eval(_ s: String) -> Bool? { WhenExpression.parse(s)?.evaluate(ctx) }
        XCTAssertEqual(eval("a"), true)
        XCTAssertEqual(eval("b"), false)
        XCTAssertEqual(eval("!b"), true)
        XCTAssertEqual(eval("a && b"), false)
        XCTAssertEqual(eval("a || b"), true)
        XCTAssertEqual(eval("a && !b && c"), true)
        XCTAssertEqual(eval("!(a && b)"), true)
        XCTAssertEqual(eval("b || a && b"), false, "&& binds tighter than ||")
        XCTAssertEqual(eval("(b || a) && c"), true)
        XCTAssertEqual(eval("unknown"), false, "unknown identifiers are false")
        XCTAssertEqual(eval("!!a"), true)
    }

    func testWhenSyntaxErrors() {
        for bad in ["", "&&", "a &&", "(a", "a)", "a b", "a & b", "a | b", "!", "1a", "a && || b", "a == b"] {
            XCTAssertNil(WhenExpression.parse(bad), bad)
        }
    }

    // MARK: Matching and precedence

    func testLastMatchingRuleWins() {
        let rules = [rule("mod+g", "one"), rule("mod+g", "two")]
        XCTAssertEqual(Keybindings.match(chord("cmd+g"), context: [:], rules: rules), "two")
    }

    func testConditionDecidesWhichRuleMatches() {
        let rules = [rule("mod+d", "diff", "!terminalFocus"), rule("mod+d", "split", "terminalFocus")]
        XCTAssertEqual(Keybindings.match(chord("mod+d"), context: ["terminalFocus": true], rules: rules), "split")
        XCTAssertEqual(Keybindings.match(chord("mod+d"), context: [:], rules: rules), "diff")
        XCTAssertNil(Keybindings.match(chord("mod+x"), context: [:], rules: rules))
    }

    func testLaterRuleWithFalseConditionFallsThroughToEarlier() {
        let rules = [rule("mod+g", "general"), rule("mod+g", "special", "turnRunning")]
        XCTAssertEqual(Keybindings.match(chord("mod+g"), context: ["turnRunning": false], rules: rules), "general")
        XCTAssertEqual(Keybindings.match(chord("mod+g"), context: ["turnRunning": true], rules: rules), "special")
    }

    func testUserRuleOverridesDefault() {
        let user = [rule("mod+k", "my.command")]
        let all = Keybindings.effective(user: user)
        XCTAssertEqual(Keybindings.match(chord("mod+k"), context: [:], rules: all), "my.command")
        XCTAssertEqual(Keybindings.match(chord("mod+k"), context: [:], rules: Keybindings.defaults), "commandPalette.toggle")
    }

    // MARK: Conflicts

    func testConflictsOnlyWhenConditionsCanOverlap() {
        XCTAssertEqual(Keybindings.conflicts([rule("mod+g", "a"), rule("mod+g", "b")]).count, 1)
        XCTAssertEqual(Keybindings.conflicts([rule("mod+g", "a"), rule("cmd+g", "b")]).count, 1, "mod is cmd")
        XCTAssertEqual(Keybindings.conflicts([rule("mod+g", "a", "x"), rule("mod+g", "b", "!x")]), [])
        XCTAssertEqual(Keybindings.conflicts([rule("mod+g", "a", "x"), rule("mod+g", "b", "y")]).count, 1)
        XCTAssertEqual(Keybindings.conflicts([rule("mod+g", "a"), rule("mod+g", "a")]), [])
        XCTAssertEqual(Keybindings.conflicts([rule("mod+g", "a"), rule("mod+h", "b")]), [])
        let c = Keybindings.conflicts([rule("mod+g", "a"), rule("mod+g", "b")])[0]
        XCTAssertEqual(c.first, 0)
        XCTAssertEqual(c.winner, 1)
    }

    // MARK: Loading

    func testLoadSkipsBadRulesAndReportsThem() {
        let json = """
        [
          {"key":"mod+g","command":"a","future":1},
          {"key":"mod+h"},
          {"command":"b"},
          {"key":"hyper+x","command":"c"},
          {"key":"mod+j","command":"d","when":"a &&"},
          "oops",
          {"key":"mod+l","command":"e","when":"turnRunning"}
        ]
        """
        let result = Keybindings.load(Data(json.utf8))
        XCTAssertEqual(result.state, .ok)
        XCTAssertEqual(result.rules.map(\.command), ["a", "e"])
        XCTAssertEqual(result.problems, [
            .init(index: 1, reason: .missingCommand), .init(index: 2, reason: .missingKey), .init(index: 3, reason: .badKey),
            .init(index: 4, reason: .badWhen), .init(index: 5, reason: .notAnObject),
        ])
    }

    func testEmptyAndInvalidFiles() {
        XCTAssertEqual(Keybindings.load(Data()).state, .empty)
        XCTAssertEqual(Keybindings.load(Data("  \n".utf8)).state, .empty)
        XCTAssertEqual(Keybindings.load(Data("[]".utf8)).state, .ok)
        XCTAssertEqual(Keybindings.load(Data("[]".utf8)).rules, [])
        for bad in ["{", "{\"key\":\"a\"}", "null", "garbage"] {
            let r = Keybindings.load(Data(bad.utf8))
            XCTAssertEqual(r.state, .unparseable, bad)
            XCTAssertEqual(r.rules, [], bad)
        }
        // The caller falls back to defaults when nothing usable loaded.
        XCTAssertEqual(Keybindings.effective(user: Keybindings.load(Data("{".utf8)).rules), Keybindings.defaults)
    }

    func testEncodeRoundTrip() {
        let rules = [rule("mod+g", "a", "x && !y"), rule("alt+up", "b")]
        XCTAssertEqual(Keybindings.load(Keybindings.encode(rules)).rules, rules)
    }

    // MARK: Defaults

    func testDefaultsAreValidKnownAndConflictFree() {
        for r in Keybindings.defaults {
            XCTAssertTrue(r.isValid, r.key)
            XCTAssertTrue(Keybindings.commandIDs.contains(r.command), r.command)
            for name in r.condition?.identifiers ?? [] { XCTAssertTrue(Keybindings.contextKeys.contains(name), name) }
        }
        XCTAssertEqual(Keybindings.conflicts(Keybindings.defaults), [])
        XCTAssertEqual(Set(Keybindings.commandIDs).count, Keybindings.commandIDs.count)
    }

    func testInterruptIsUnboundByDefault() {
        XCTAssertTrue(Keybindings.commandIDs.contains("session.interrupt"))
        XCTAssertFalse(Keybindings.defaults.contains { $0.command == "session.interrupt" })
    }

    func testSendAndFlipFollowUpDependOnTurnRunning() {
        let d = Keybindings.defaults
        XCTAssertEqual(Keybindings.match(chord("mod+enter"), context: ["composerFocus": true], rules: d), "composer.send")
        XCTAssertEqual(Keybindings.match(chord("mod+enter"), context: ["composerFocus": true, "turnRunning": true], rules: d), "composer.sendAlternate")
        XCTAssertEqual(Keybindings.match(chord("shift+enter"), context: ["composerFocus": true], rules: d), "composer.newline")
        XCTAssertNil(Keybindings.match(chord("mod+enter"), context: [:], rules: d))
        XCTAssertEqual(Keybindings.match(chord("mod+shift+]"), context: [:], rules: d), "session.next")
    }
}
