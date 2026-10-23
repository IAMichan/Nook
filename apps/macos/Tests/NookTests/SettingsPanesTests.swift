import XCTest

/// Where things are in System Settings: a task Nook takes over gets the pane that fits it, with the link to open it.
final class SettingsPanesTests: XCTestCase {
    private func first(_ task: String) -> String? { SettingsPanes.matching(task).first?.name }

    func testTasksFindTheirPaneInEveryLanguage() {
        XCTAssertEqual(first("Zet Night Shift aan tot morgen"), "Displays")
        XCTAssertEqual(first("Laat het batterijpercentage in de menubalk zien"), "Control Center")
        XCTAssertEqual(first("Verander mijn standaardbrowser naar Firefox"), "Desktop & Dock")
        XCTAssertEqual(first("Make the key repeat faster on my keyboard"), "Keyboard")
        XCTAssertEqual(first("Turn on tap to click"), "Trackpad")
        XCTAssertEqual(first("Stelle die Bildschirmzeit ein"), "Screen Time")
        XCTAssertEqual(first("Active le mode sombre"), "Appearance")
        XCTAssertEqual(first("Cambia el idioma a español"), "Language & Region")
        XCTAssertTrue(SettingsPanes.matching("Bestel koffiefilters bij bol.com").isEmpty)
    }

    func testTheGuideCarriesTheLinkAndWhatIsThere() {
        let guide = SettingsPanes.guide(for: "zet night shift aan")
        XCTAssertTrue(guide.contains("x-apple.systempreferences:com.apple.Displays-Settings.extension"), guide)
        XCTAssertTrue(guide.contains("Night Shift…"), guide)
        XCTAssertEqual(SettingsPanes.guide(for: "order coffee filters"), "")
        for pane in SettingsPanes.all {
            XCTAssertTrue(UIControl.isSettingsPane(pane.url), pane.url)
        }
        XCTAssertEqual(Set(SettingsPanes.all.map(\.id)).count, SettingsPanes.all.count, "no pane twice")
    }

    func testATakeoverPromptPointsAtThePane() {
        let prompt = TakeoverPolicy.prompt(task: "Zet Night Shift aan", frontApp: "Finder", window: "", screen: "", memories: [],
                                           dates: "Dates: today")
        XCTAssertTrue(prompt.contains("Where this probably is in System Settings"))
        XCTAssertTrue(prompt.contains("com.apple.Displays-Settings.extension"))
    }
}
