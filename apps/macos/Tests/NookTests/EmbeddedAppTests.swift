import XCTest

/// "@open whatsapp" and friends: which chat messages open an app next to the chat, and which stay questions.
final class EmbeddedAppTests: XCTestCase {
    /// Without Mac apps, so the web catalog is what is tested whatever is installed on the Mac running the tests.
    private func opened(_ text: String, installed: [EmbeddedApp] = []) -> String? {
        if case .open(let app, _) = EmbeddedAppCatalog.command(in: text, installed: installed) { return app.id }
        return nil
    }

    private let macApps = InstalledMacApps.make(paths: [
        "/Applications/WhatsApp.app", "/System/Applications/Calendar.app", "/Applications/Microsoft Word.app",
        "/Applications/Nook.app", "/Users/me/Applications/WhatsApp.app"
    ])

    func testOpenCommands() {
        XCTAssertEqual(opened("@open whatsapp"), "whatsapp")
        XCTAssertEqual(opened("@open WhatsApp"), "whatsapp")
        XCTAssertEqual(opened("@open whats app"), "whatsapp")
        XCTAssertEqual(opened("@whatsapp"), "whatsapp")
        XCTAssertEqual(opened("@openen gmail"), "gmail")
        XCTAssertEqual(opened("@open google calendar"), "calendar")
        XCTAssertEqual(opened("open whatsapp in nook"), "whatsapp")
        XCTAssertEqual(opened("öffne Slack im Nook"), "slack")
    }

    func testWebAddressesOpenAsTheirOwnApp() {
        guard case .open(let app, _) = EmbeddedAppCatalog.command(in: "@open notion.so/my-page", installed: []) else { return XCTFail("not opened") }
        XCTAssertEqual(app.url.absoluteString, "https://notion.so/my-page")
        XCTAssertEqual(app.title, "notion.so")
        XCTAssertNil(EmbeddedAppCatalog.webApp("http://example.com"), "only https")
        XCTAssertNil(EmbeddedAppCatalog.webApp("lisa@example.com"))
    }

    func testCloseAndUnknown() {
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@close"), .close)
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@sluit"), .close)
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open foo bar"), .unknown("foo bar"))
    }

    func testOtherMessagesStayQuestions() {
        XCTAssertNil(EmbeddedAppCatalog.command(in: "@Lisa wat vind jij?"))
        XCTAssertNil(EmbeddedAppCatalog.command(in: "Open WhatsApp"), "the Mac app, through open_app")
        XCTAssertNil(EmbeddedAppCatalog.command(in: "Wat staat er in WhatsApp?"))
        XCTAssertNil(EmbeddedAppCatalog.command(in: "lisa@example.com"))
    }

    func testMentionList() {
        XCTAssertEqual(EmbeddedAppCatalog.matching(EmbeddedAppCatalog.mentionQuery("open")).count, EmbeddedAppCatalog.all.count)
        XCTAssertEqual(EmbeddedAppCatalog.matching(EmbeddedAppCatalog.mentionQuery("wh")).first?.id, "whatsapp")
    }

    func testEachAppKeepsItsOwnStore() {
        let ids = EmbeddedAppCatalog.all.map(\.storeID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(EmbeddedAppCatalog.storeID(for: "whatsapp"), EmbeddedAppCatalog.storeID(for: "whatsapp"), "the same every launch")
    }

    func testSplitKeepsBothSidesUsable() {
        XCTAssertEqual(EmbeddedSplit.chatWidth(500, total: 1200), 500)
        XCTAssertEqual(EmbeddedSplit.chatWidth(100, total: 1200), EmbeddedSplit.minimumChat, "the chat never gets too narrow")
        XCTAssertEqual(EmbeddedSplit.chatWidth(5000, total: 1200), 1200 - EmbeddedSplit.minimumApp - EmbeddedSplit.handle, "nor does the app")
        XCTAssertEqual(EmbeddedSplit.chatWidth(400, total: 0), 400, "width not known yet")
        XCTAssertEqual(EmbeddedSplit.chatWidth(400, total: 500), EmbeddedSplit.minimumChat, "too small for both: the chat keeps its minimum")
    }

    func testPanelSplitKeepsBothSidesUsable() {
        XCTAssertEqual(PanelSplit.width(320, minimum: 220, available: 1000, rest: 400), 320)
        XCTAssertEqual(PanelSplit.width(100, minimum: 220, available: 1000, rest: 400), 220, "never narrower than its minimum")
        XCTAssertEqual(PanelSplit.width(900, minimum: 220, available: 1000, rest: 400), 600, "leaves the rest its room")
        XCTAssertEqual(PanelSplit.width(900, minimum: 220, available: 0, rest: 400), 900, "width not known yet")
        XCTAssertEqual(PanelSplit.width(300, minimum: 220, available: 500, rest: 400), 220, "too small for both: the panel keeps its minimum")
        XCTAssertEqual(PanelSplit.dragged(from: 400, offset: -50, handleOnLeading: true), 450, "a right-hand panel widens to the left")
        XCTAssertEqual(PanelSplit.dragged(from: 280, offset: 40, handleOnLeading: false), 320, "a left-hand panel widens to the right")
    }

    func testManyAppsOpenByName() {
        XCTAssertEqual(opened("@open trello"), "trello")
        XCTAssertEqual(opened("@open ChatGPT"), "chatgpt")
        XCTAssertEqual(opened("@open google docs"), "docs")
        XCTAssertEqual(opened("@open bol.com"), "bol", "a known app wins over the web address")
        XCTAssertEqual(opened("@open disney+"), "disneyplus")
        XCTAssertEqual(opened("@github"), "github")
        XCTAssertGreaterThanOrEqual(EmbeddedAppCatalog.all.count, 100)
    }

    func testCatalogIsWellFormed() {
        let ids = EmbeddedAppCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "no app twice")
        for app in EmbeddedAppCatalog.all {
            XCTAssertEqual(app.url.scheme, "https", app.id)
            XCTAssertEqual(EmbeddedAppCatalog.find(app.title, installed: [])?.id, app.id, "\(app.title) opens itself, not another app")
        }
    }

    func testUnknownNamesGetSuggestions() {
        XCTAssertEqual(EmbeddedAppCatalog.suggestions(for: "whatsap", installed: []).first?.id, "whatsapp")
        XCTAssertFalse(EmbeddedAppCatalog.suggestions(for: "qqqq", installed: []).isEmpty, "always something to try")
        XCTAssertEqual(EmbeddedAppCatalog.suggestions(for: "whatsap", installed: macApps).first?.id, "mac:whatsapp")
    }

    func testInstalledMacAppsComeFirst() {
        XCTAssertEqual(macApps.map(\.id), ["mac:whatsapp", "mac:calendar", "mac:microsoftword"], "one per name, never Nook itself")
        XCTAssertTrue(macApps.allSatisfy(\.isMacApp))
        XCTAssertFalse(EmbeddedAppCatalog.all.contains(where: \.isMacApp))
        XCTAssertEqual(macApps.first?.url.path, "/Applications/WhatsApp.app")

        XCTAssertEqual(opened("@open whatsapp", installed: macApps), "mac:whatsapp")
        XCTAssertEqual(opened("@whatsapp", installed: macApps), "mac:whatsapp")
        XCTAssertEqual(opened("@open wa", installed: macApps), "mac:whatsapp", "the web app's names carry over")
        XCTAssertEqual(opened("@open word", installed: macApps), "mac:microsoftword")
        XCTAssertEqual(opened("@open Microsoft Word", installed: macApps), "mac:microsoftword")
        XCTAssertEqual(opened("@open calendar", installed: macApps), "mac:calendar")
        XCTAssertEqual(opened("@open google calendar", installed: macApps), "calendar", "Apple's Calendar is not Google's")
        XCTAssertEqual(opened("@open gmail", installed: macApps), "gmail", "not installed: the web app")
    }

    func testWebVersionStaysReachable() {
        XCTAssertEqual(opened("@open whatsapp web", installed: macApps), "whatsapp")
        XCTAssertEqual(opened("@open slack web", installed: macApps), "slack")
        XCTAssertEqual(opened("@open word web", installed: macApps), "word")
    }

    func testOtherWaysToOpen() {
        let mac = macApps[0], word = macApps[2]
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open whatsapp web", installed: macApps),
                       .open(EmbeddedAppCatalog.find("whatsapp", installed: [])!, .web))
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open whatsapp venster", installed: macApps), .open(mac, .window))
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open WhatsApp window", installed: macApps), .open(mac, .window))
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open whatsapp mac", installed: macApps), .open(mac, .mirror))
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open whatsapp", installed: macApps), .open(mac, nil), "no way asked for")
        XCTAssertEqual(opened("@open microsoft word venster", installed: macApps), word.id)
        XCTAssertEqual(EmbeddedAppCatalog.command(in: "@open gmail venster", installed: macApps),
                       .open(EmbeddedAppCatalog.find("gmail", installed: [])!, .web), "no Mac app: the web version after all")

        XCTAssertEqual(EmbeddedAppCatalog.modes(for: mac, installed: macApps), [.mirror, .web, .window])
        XCTAssertEqual(EmbeddedAppCatalog.modes(for: EmbeddedAppCatalog.webVersion(of: mac)!, installed: macApps), [.mirror, .web, .window],
                       "the web version can switch back to the Mac app")
        XCTAssertEqual(EmbeddedAppCatalog.modes(for: macApps[1], installed: macApps), [.mirror, .window], "Apple's Calendar has no web version")
        XCTAssertEqual(EmbeddedAppCatalog.modes(for: EmbeddedAppCatalog.find("gmail", installed: [])!, installed: macApps), [.web])
        XCTAssertEqual(EmbeddedAppCatalog.family(of: mac), "whatsapp")
        XCTAssertEqual(EmbeddedAppCatalog.resolve(mac, mode: .web, installed: macApps).app.id, "whatsapp")
        XCTAssertEqual(EmbeddedAppCatalog.resolve(mac, mode: nil, installed: macApps).mode, .mirror)
    }

    func testChosenWayIsRemembered() {
        let defaults = UserDefaults(suiteName: "nook.tests.embedded")!
        defer { defaults.removePersistentDomain(forName: "nook.tests.embedded") }
        let mac = macApps[0]
        XCTAssertNil(EmbeddedAppPreference.mode(for: mac, defaults: defaults))
        EmbeddedAppPreference.remember(.web, for: EmbeddedAppCatalog.webVersion(of: mac)!, defaults: defaults)
        XCTAssertEqual(EmbeddedAppPreference.mode(for: mac, defaults: defaults), .web, "one choice for the Mac and web versions")
    }

    func testMentionListHasMacAppsWithoutDoubles() {
        let apps = EmbeddedAppCatalog.available(installed: macApps)
        XCTAssertEqual(Array(apps.prefix(3)).map(\.id), macApps.map(\.id))
        XCTAssertFalse(apps.contains { $0.id == "whatsapp" }, "WhatsApp Web is covered by the Mac app")
        XCTAssertTrue(apps.contains { $0.id == "calendar" }, "Google Calendar stays")
        XCTAssertEqual(EmbeddedAppCatalog.matching("wh", in: apps).first?.id, "mac:whatsapp")
    }

    func testMirrorMapsThePictureOntoTheWindow() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)
        // Same size: one to one.
        XCTAssertEqual(MirrorGeometry.screenPoint(CGPoint(x: 10, y: 20), view: CGSize(width: 800, height: 600), window: window),
                       CGPoint(x: 110, y: 70))
        // Half size, centred vertically in a taller pane (400 x 300 picture, 50 empty above and below).
        let pane = CGSize(width: 400, height: 400)
        XCTAssertEqual(MirrorGeometry.screenPoint(CGPoint(x: 200, y: 200), view: pane, window: window), CGPoint(x: 500, y: 350))
        XCTAssertEqual(MirrorGeometry.screenPoint(CGPoint(x: 0, y: 50), view: pane, window: window), CGPoint(x: 100, y: 50))
        XCTAssertNil(MirrorGeometry.screenPoint(CGPoint(x: 200, y: 20), view: pane, window: window), "the empty margin")
        XCTAssertNil(MirrorGeometry.screenPoint(.zero, view: .zero, window: window))
    }
}
