import XCTest

/// The settings Nook's chat may change: words become values, and a change can be undone.
final class SettingsCatalogTests: XCTestCase {
    func testSwitchesUnderstandWordsInEveryLanguage() throws {
        let search = try XCTUnwrap(SettingsCatalog.entry("web_search"))
        for word in ["on", "aan", "Ja", " true ", "an", "oui", "sí"] {
            XCTAssertEqual(SettingsCatalog.value(word, for: search), "on", word)
        }
        for word in ["off", "uit", "nee", "aus", "non", "false"] {
            XCTAssertEqual(SettingsCatalog.value(word, for: search), "off", word)
        }
        XCTAssertNil(SettingsCatalog.value("misschien", for: search))
    }

    func testChoicesTakeOptionsAndNames() throws {
        let language = try XCTUnwrap(SettingsCatalog.entry("app_language"))
        XCTAssertEqual(SettingsCatalog.value("en", for: language), "en")
        XCTAssertEqual(SettingsCatalog.value("Engels", for: language), "en")
        XCTAssertEqual(SettingsCatalog.value("Deutsch", for: language), "de")
        XCTAssertNil(SettingsCatalog.value("auto", for: language), "only answers follow the question")
        XCTAssertNil(SettingsCatalog.value("klingon", for: language))
        let answers = try XCTUnwrap(SettingsCatalog.entry("answer_language"))
        XCTAssertEqual(SettingsCatalog.value("auto", for: answers), "auto")
        let placement = try XCTUnwrap(SettingsCatalog.entry("notch_placement"))
        XCTAssertEqual(SettingsCatalog.value("zwevend", for: placement), "floating")
        XCTAssertNil(SettingsCatalog.value("on", for: placement))
    }

    func testNothingThatWidensWhatNookMayDo() {
        for id in ["auto_run_safe", "provider", "use_local", "local_only_sources", "brain"] {
            XCTAssertNil(SettingsCatalog.entry(id), id)
        }
        XCTAssertEqual(Set(SettingsCatalog.ids).count, SettingsCatalog.ids.count, "ids are unique")
    }

    func testAChangeCanBeUndone() {
        let result = SettingsCatalog.result("web_search", value: "on", old: "off")
        XCTAssertEqual(SettingsCatalog.previous(in: result), "off")
        XCTAssertEqual(Undo.step(tool: "change_setting", input: ["setting": "web_search", "value": "on"], result: result),
                       Undo.Step(tool: "change_setting", input: ["setting": "web_search", "value": "off"]))
        XCTAssertNil(Undo.step(tool: "change_setting", input: ["setting": "web_search"], result: "web_search: on"))
    }

    func testTheSchemaListsEverySetting() {
        let properties = SettingsCatalog.changeSchema["properties"] as? [String: Any]
        let setting = properties?["setting"] as? [String: Any]
        XCTAssertEqual(setting?["enum"] as? [String], SettingsCatalog.ids)
        XCTAssertEqual(SettingsCatalog.changeSchema["required"] as? [String], ["setting", "value"])
    }
}
