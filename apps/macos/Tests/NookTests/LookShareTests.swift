import XCTest

/// Sharing the look as a `.nooklook` file: what goes in, how it reads back, and how an imported theme lands next to the
/// receiver's own.
final class LookShareTests: XCTestCase {
    private let vscodeTheme = ##"{"name": "Dusk", "type": "dark", "colors": {"editor.background": "#101820", "editor.foreground": "#E0E0E0"}}"##

    private func sample(customThemes: [NookCustomTheme] = []) -> NookLookShare {
        var overrides = NookColorOverrides()
        overrides.dark = ["canvas": 0x111111, "chatMine": 0x2244AA]
        overrides.light = ["paper": 0x202020]
        let choice = NookThemeChoice(mode: .system, darkTheme: customThemes.first?.id ?? "midnight", lightTheme: "paper",
                                     overrides: overrides)
        return NookLookShare(accent: 0x8B7BFF, choice: choice, customThemes: customThemes, diffColors: .blueOrange,
                             density: .compact, look: .playful)
    }

    func testRoundTripKeepsEverything() throws {
        let share = sample()
        let read = try NookLookShare.decode(share.encoded())
        XCTAssertEqual(read, share)
        XCTAssertEqual(read.accent, 0x8B7BFF)
        XCTAssertEqual(read.mode, .system)
        XCTAssertEqual(read.darkTheme, "midnight")
        XCTAssertEqual(read.overrides.dark["chatMine"], 0x2244AA)
        XCTAssertEqual(read.look, .playful)
    }

    func testColorsAreWrittenAsHexText() throws {
        let text = String(decoding: sample().encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"#8B7BFF\""))
        XCTAssertTrue(text.contains("\"#111111\""))
        XCTAssertTrue(text.contains("\"nook-look\""))
    }

    func testOnlyTheImportedThemesInUseTravel() {
        let used = NookCustomTheme(id: "custom-a", name: "Dusk", source: vscodeTheme)
        let unused = NookCustomTheme(id: "custom-b", name: "Other", source: vscodeTheme)
        XCTAssertEqual(sample(customThemes: [used, unused]).themes, [used])
    }

    func testOtherFilesAreRefused() {
        XCTAssertThrowsError(try NookLookShare.decode(Data(vscodeTheme.utf8)))
        XCTAssertThrowsError(try NookLookShare.decode(Data("not json".utf8)))
    }

    func testUnknownValuesKeepTheReceiversSettings() throws {
        let json = ##"{"format": "nook-look", "version": 9, "appearance": "neon", "density": "huge", "accent": "blue","##
            + ##" "dark": {"theme": "midnight", "colors": {"canvas": "#010203", "glitter": "#FFFFFF", "paper": "oops"}}}"##
        let read = try NookLookShare.decode(Data(json.utf8))
        XCTAssertNil(read.mode)
        XCTAssertNil(read.density)
        XCTAssertNil(read.accent)
        XCTAssertNil(read.look)
        XCTAssertEqual(read.overrides.dark, ["canvas": 0x010203])
        XCTAssertNil(read.lightTheme)
        let themes = read.themes(mergedInto: [], darkTheme: "nook", lightTheme: "warm")
        XCTAssertEqual(themes.darkTheme, "midnight")
        XCTAssertEqual(themes.lightTheme, "warm")
    }

    func testImportedThemeIsAddedOnceAndChosen() throws {
        let theme = NookCustomTheme(id: "custom-a", name: "Dusk", source: vscodeTheme)
        let read = try NookLookShare.decode(sample(customThemes: [theme]).encoded())
        let first = read.themes(mergedInto: [], darkTheme: "nook", lightTheme: "nook")
        XCTAssertEqual(first.customThemes, [theme])
        XCTAssertEqual(first.darkTheme, "custom-a")
        XCTAssertEqual(first.lightTheme, "paper")
        // Importing the same file again reuses the theme they already have, under its own id.
        var mine = theme
        mine.id = "custom-mine"
        let again = read.themes(mergedInto: [mine], darkTheme: "nook", lightTheme: "nook")
        XCTAssertEqual(again.customThemes, [mine])
        XCTAssertEqual(again.darkTheme, "custom-mine")
    }

    func testThemeWithATakenIDGetsANewOne() throws {
        let theme = NookCustomTheme(id: "custom-a", name: "Dusk", source: vscodeTheme)
        let read = try NookLookShare.decode(sample(customThemes: [theme]).encoded())
        let other = NookCustomTheme(id: "custom-a", name: "Mine", source: vscodeTheme.replacingOccurrences(of: "Dusk", with: "Mine"))
        let result = read.themes(mergedInto: [other], darkTheme: "nook", lightTheme: "nook", newID: { "custom-new" })
        XCTAssertEqual(result.customThemes.map(\.id), ["custom-a", "custom-new"])
        XCTAssertEqual(result.darkTheme, "custom-new")
    }

    func testThemeMissingFromTheFileKeepsTheReceiversChoice() throws {
        let json = ##"{"format": "nook-look", "dark": {"theme": "custom-gone"}}"##
        let read = try NookLookShare.decode(Data(json.utf8))
        XCTAssertEqual(read.themes(mergedInto: [], darkTheme: "warm", lightTheme: "nook").darkTheme, "warm")
    }
}
