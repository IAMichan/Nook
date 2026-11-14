import XCTest

/// Double Tap in a browser through Nook's extension: which connected browser is the one in front, how the page agent's
/// form reads, what `fill` gets, and the line above the field that says what Nook sees.
final class DoubleTapBrowserTests: XCTestCase {
    private let now = Date()

    private func client(_ id: String, _ browser: String) -> BrowserExtensionClient {
        BrowserExtensionClient(id: id, browser: browser, lastSeen: now, lastActive: now)
    }

    func testTheBrowserInFrontIsFoundByItsName() {
        let clients = [client("a", "Google Chrome"), client("b", "Brave")]
        XCTAssertEqual(DoubleTapLogic.browserClient(appName: "Google Chrome", bundleID: "com.google.Chrome", clients: clients)?.id, "a")
        XCTAssertEqual(DoubleTapLogic.browserClient(appName: "Brave Browser", bundleID: "com.brave.Browser", clients: clients)?.id, "b")
        // Arc says hello as another brand: with two browsers connected Nook does not guess.
        XCTAssertNil(DoubleTapLogic.browserClient(appName: "Arc", bundleID: "company.thebrowser.Browser", clients: clients))
        XCTAssertEqual(DoubleTapLogic.browserClient(appName: "Arc", bundleID: "company.thebrowser.Browser",
                                                    clients: [client("c", "Google Chrome")])?.id, "c")
    }

    func testTwoBrowsersThatBothSayChromeAreToldApartByProcess() {
        // Chrome runs as pid 500 and Arc as pid 600; each started the host of its own extension (a helper in between).
        let chrome = client("501-1700000000-0a1b", "Google Chrome")
        let arc = client("611-1700000000-0c2d", "Google Chrome")
        let parents: [Int32: Int32] = [501: 500, 611: 610, 610: 600, 500: 1, 600: 1]
        let parent: (Int32) -> Int32? = { parents[$0] }
        XCTAssertEqual(arc.hostPID, 611)
        XCTAssertEqual(DoubleTapLogic.browserClient(appName: "Arc", bundleID: "company.thebrowser.Browser", appPID: 600,
                                                    clients: [chrome, arc], parent: parent)?.id, arc.id)
        XCTAssertEqual(DoubleTapLogic.browserClient(appName: "Google Chrome", bundleID: "com.google.Chrome", appPID: 500,
                                                    clients: [arc, chrome], parent: parent)?.id, chrome.id)
        // Arc in front without its own extension: Chrome's is not taken for it, though it is the only one connected.
        XCTAssertNil(DoubleTapLogic.browserClient(appName: "Arc", bundleID: "company.thebrowser.Browser", appPID: 600,
                                                  clients: [chrome], parent: parent))
        // A host Nook cannot trace falls back to the browser's name.
        let untraced = client("901-1700000000-0e3f", "Brave")
        XCTAssertEqual(DoubleTapLogic.browserClient(appName: "Brave Browser", bundleID: "com.brave.Browser", appPID: 700,
                                                    clients: [chrome, untraced], parent: parent)?.id, untraced.id)
    }

    func testOnlyAChromiumBrowserUsesTheExtension() {
        let clients = [client("a", "Google Chrome")]
        XCTAssertNil(DoubleTapLogic.browserClient(appName: "Safari", bundleID: "com.apple.Safari", clients: clients))
        XCTAssertNil(DoubleTapLogic.browserClient(appName: "Pages", bundleID: "com.apple.iWork.Pages", clients: clients))
        XCTAssertNil(DoubleTapLogic.browserClient(appName: "Google Chrome", bundleID: "com.google.Chrome", clients: []))
    }

    private let form = """
    {"title":"Sign up","url":"https://example.com/join","selection":"",
     "fields":[
       {"ref":"e1","role":"field","label":"Name","value":"","focused":true,"secure":false,"settable":true},
       {"ref":"e2","role":"field","label":"","value":"","focused":false,"secure":false,"settable":true,"autocomplete":"email"},
       {"ref":"e3","role":"password","label":"Password","value":"","focused":false,"secure":true,"settable":true},
       {"ref":"e4","role":"combobox","label":"Country","value":"","focused":false,"secure":false,"settable":true,"options":["Netherlands","Belgium"]}
     ],
     "pieces":[{"text":"Create your account"},{"field":0},{"text":"We never share your email"},{"field":1},{"field":2},{"field":3}],
     "buttons":[{"ref":"e9","label":"Cancel"},{"ref":"e10","label":"Create account"}],"preferred":1,
     "focus":{"role":"field","empty":true,"placeholder":"","secure":false}}
    """

    func testAFormReadByTheExtension() throws {
        let page = try XCTUnwrap(DoubleTapLogic.page(fromJSON: form))
        XCTAssertEqual(page.title, "Sign up")
        XCTAssertEqual(page.refs, ["e1", "e2", "e3", "e4"])
        XCTAssertEqual(page.fields[1].label, "email", "the autofill hint names a field without a label")
        XCTAssertEqual(page.fields[3].label, "Country (options: Netherlands, Belgium)")
        XCTAssertEqual(DoubleTapLogic.shownLabel(page.fields[3].label), "Country")
        XCTAssertTrue(page.fields[2].secure)
        XCTAssertEqual(page.submit?.ref, "e10")
        XCTAssertEqual(page.pieces.first, .text("Create your account"))
        XCTAssertEqual(page.focus, .field)

        // The password field never goes to the brain, and the focused field comes first.
        let fields = DoubleTapLogic.candidates(page.fields)
        XCTAssertEqual(fields.map(\.label), ["Name", "email", "Country (options: Netherlands, Belgium)"])
        let values = DoubleTapLogic.fillValues([1: "Ada Lovelace", 3: "Netherlands"], fields: fields, page: page)
        XCTAssertEqual(values, [["ref": "e1", "value": "Ada Lovelace"], ["ref": "e4", "value": "Netherlands"]])
        XCTAssertEqual(DoubleTapLogic.written(fromFill: #"{"written":["e1","e4"]}"#), ["e1", "e4"])
    }

    func testThePageTellsTheSuggestionsWhatIsThere() throws {
        let page = try XCTUnwrap(DoubleTapLogic.page(fromJSON: form))
        let scene = DoubleTapLogic.scene(of: page, app: "Google Chrome", bundleID: "com.google.Chrome")
        XCTAssertTrue(scene.viaExtension)
        XCTAssertEqual(scene.emptyFields, 3)
        XCTAssertEqual(scene.focus, .field)
        XCTAssertNil(DoubleTapLogic.page(fromJSON: "not json"))
    }

    func testTheUsersBrakeInTheExtensionIsKept() {
        XCTAssertTrue(DoubleTapLogic.extensionRefused("The user paused Nook in this browser (the side panel)."))
        XCTAssertTrue(DoubleTapLogic.extensionRefused("The user switched Nook off for example.com in the side panel."))
        XCTAssertFalse(DoubleTapLogic.extensionRefused(BrowserExtensionOutcome.notConnected.error))
        XCTAssertFalse(DoubleTapLogic.extensionRefused(BrowserExtensionOutcome.timedOut(after: 4).error))
    }

    func testTheLineAboveTheFieldSaysWhatNookSees() throws {
        if tr("doubletap.hint.form") == "doubletap.hint.form" { throw XCTSkip("translations are shimmed") }
        XCTAssertEqual(DoubleTapLogic.hint(app: "", scene: nil, language: .en).symbol, "sparkles")
        XCTAssertEqual(DoubleTapLogic.hint(app: "Pages", scene: nil, language: .en).text, "Pages · Looking at what is in front…")
        var form = DoubleTapScene(app: "Google Chrome", focus: .field, emptyFields: 4)
        form.viaExtension = true
        let hint = DoubleTapLogic.hint(app: "Google Chrome", scene: form, language: .en)
        XCTAssertEqual(hint.text, "Google Chrome · 4 empty fields: Nook can fill them in")
        XCTAssertEqual(hint.badge, "Via your browser")
        let selection = DoubleTapScene(app: "Pages", focus: .text, selection: "Three little words", focusEmpty: false)
        XCTAssertEqual(DoubleTapLogic.hint(app: "Pages", scene: selection, language: .en).text,
                       "Pages · 3 words selected: improve, translate or explain them")
        XCTAssertNil(DoubleTapLogic.hint(app: "Pages", scene: selection, language: .en).badge)
        let blocked = DoubleTapScene(app: "1Password", blocked: true)
        XCTAssertEqual(DoubleTapLogic.hint(app: "1Password", scene: blocked, language: .nl).symbol, "hand.raised")
    }
}
