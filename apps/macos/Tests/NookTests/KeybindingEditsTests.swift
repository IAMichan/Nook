import XCTest

final class KeybindingEditsTests: XCTestCase {
    private func chord(_ text: String) -> KeyChord { KeyChord.parse(text)! }

    private func rules(_ data: Data) -> [KeybindingRule] { Keybindings.load(data).rules }

    func testRuleKeyWritesModForCommand() {
        let pressed = KeyChord.pressed(characters: "j", keyCode: 38, command: true, control: false, option: true, shift: false)!
        XCTAssertEqual(KeybindingEdits.ruleKey(pressed), "mod+alt+j")
        XCTAssertEqual(KeybindingEdits.ruleKey(chord("cmd++")), "mod++")
        XCTAssertEqual(KeyChord.parse(KeybindingEdits.ruleKey(chord("ctrl+f6")))?.resolved, chord("ctrl+f6"))
    }

    func testOnlyKeysThatDoNotTypeCanBeRecorded() {
        XCTAssertTrue(KeybindingEdits.isRecordable(chord("mod+k")))
        XCTAssertTrue(KeybindingEdits.isRecordable(chord("f6")))
        XCTAssertTrue(KeybindingEdits.isRecordable(chord("alt+up")))
        XCTAssertFalse(KeybindingEdits.isRecordable(chord("k")))
        XCTAssertFalse(KeybindingEdits.isRecordable(chord("shift+k")))
        XCTAssertFalse(KeybindingEdits.isRecordable(chord("escape")))
    }

    func testRecordingReplacesTheDefaultKeyAndKeepsItsCondition() throws {
        let added = KeybindingEdits.recordedRules(chord("mod+alt+m"), for: "modelPicker.toggle")
        let data = try KeybindingEdits.apply(nil, command: "modelPicker.toggle", rules: added)
        let user = rules(data)
        let effective = Keybindings.effective(user: user)
        XCTAssertEqual(Keybindings.chords(for: "modelPicker.toggle", rules: effective), [chord("cmd+alt+m")])
        XCTAssertEqual(user.last?.when, "!terminalFocus", "the default's condition goes along")
        XCTAssertNil(Keybindings.match(chord("mod+shift+m"), context: [:], rules: effective), "the old key is off")
        XCTAssertEqual(Keybindings.match(chord("mod+alt+m"), context: [:], rules: effective), "modelPicker.toggle")
        XCTAssertTrue(KeybindingEdits.isCustomized("modelPicker.toggle", user: user))
        XCTAssertEqual(Keybindings.unknownCommands(user), [], "a switched-off default is not an unknown command")
        XCTAssertEqual(Keybindings.conflicts(effective), [])
    }

    func testRecordingTheDefaultKeyAgainAddsNoRemoval() {
        let added = KeybindingEdits.recordedRules(chord("mod+shift+m"), for: "modelPicker.toggle")
        XCTAssertEqual(added.map(\.command), ["modelPicker.toggle"])
    }

    func testApplyKeepsOtherEntriesAndResetRemovesOnlyTheCommand() throws {
        let file = Data(#"[{"key":"mod+g","command":"chat.find"},{"broken":true},{"key":"mod+e","command":"session.pin"}]"#.utf8)
        let recorded = try KeybindingEdits.apply(file, command: "session.pin",
                                                 rules: KeybindingEdits.recordedRules(chord("mod+alt+p"), for: "session.pin"))
        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: recorded) as? [Any])
        XCTAssertEqual(list.count, 4, "chat.find, the broken entry, the switched-off default and the new key")
        XCTAssertFalse(rules(recorded).contains { $0.key == "mod+e" })
        XCTAssertTrue(rules(recorded).contains { $0.key == "mod+g" && $0.command == "chat.find" })

        let reset = try KeybindingEdits.apply(recorded, command: "session.pin", rules: [])
        XCTAssertFalse(KeybindingEdits.isCustomized("session.pin", user: rules(reset)))
        XCTAssertEqual(Keybindings.chords(for: "session.pin", rules: Keybindings.effective(user: rules(reset))),
                       [chord("cmd+shift+p")])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: reset) as? [Any])?.count, 2)
    }

    func testAnUnreadableFileIsNotOverwritten() {
        XCTAssertThrowsError(try KeybindingEdits.apply(Data("{oops".utf8), command: "session.pin", rules: [])) { error in
            XCTAssertEqual(error as? KeybindingEdits.Failure, .unreadable)
        }
        XCTAssertNoThrow(try KeybindingEdits.apply(Data("  \n".utf8), command: "session.pin", rules: []))
    }

    func testConflictsOfARecording() {
        // ⌘K is search everywhere: giving it to the palette too claims the same key in the same place.
        XCTAssertEqual(KeybindingEdits.conflicts(recording: chord("mod+k"), for: "commandPalette.toggle", user: []),
                       ["search.toggle"])
        // ⌘D in a terminal splits it; the diff only takes ⌘D outside one, so it does not compete.
        XCTAssertEqual(KeybindingEdits.conflicts(recording: chord("mod+alt+x"), for: "diff.toggle", user: []), [])
    }

    func testNewCommandsAreWiredAndListed() {
        for command in ["modelPicker.toggle", "session.settle", "session.pin", "session.interrupt", "session.back",
                        "tab.close", "focus.next", "terminal.splitRight", "composer.startInBackground", "session.jump9"] {
            XCTAssertTrue(Keybindings.commandIDs.contains(command), command)
        }
        // ⌘D: the diff outside a terminal, a split inside one.
        XCTAssertEqual(Keybindings.match(chord("mod+d"), context: [:], rules: Keybindings.defaults), "diff.toggle")
        XCTAssertEqual(Keybindings.match(chord("mod+d"), context: ["terminalFocus": true], rules: Keybindings.defaults),
                       "terminal.splitRight")
        // ⌘W only with a terminal or a panel tab focused; otherwise it closes the window.
        XCTAssertNil(Keybindings.match(chord("mod+w"), context: [:], rules: Keybindings.defaults))
        XCTAssertEqual(Keybindings.match(chord("mod+w"), context: ["panelFocus": true], rules: Keybindings.defaults), "tab.close")
    }
}
