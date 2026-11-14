import XCTest

final class AppCatalogTests: XCTestCase {
    func testWhatsAppIsBothACallAndAChatApp() {
        XCTAssertEqual(AppCatalog.kinds(bundleID: "net.whatsapp.WhatsApp"), [.call, .chat])
        XCTAssertEqual(AppCatalog.kinds(bundleID: "com.apple.mail"), [.mail])
    }

    func testBrowserHelpersCountAsTheirBrowser() {
        XCTAssertTrue(AppCatalog.isBrowser("com.google.Chrome.helper"))
        XCTAssertTrue(AppCatalog.isBrowser("com.apple.SafariTechnologyPreview"))
        XCTAssertFalse(AppCatalog.isBrowser("com.apple.mail"))
        XCTAssertFalse(AppCatalog.isBrowser(""))
    }

    func testEveryKnownBrowserIsABrowser() {
        for browser in AppCatalog.browsers {
            XCTAssertTrue(AppCatalog.isBrowser(browser.bundleID), browser.name)
        }
        for bundle in AppCatalog.chromiumBundles {
            XCTAssertTrue(AppCatalog.isBrowser(bundle), bundle)
        }
        XCTAssertFalse(AppCatalog.chromiumBundles.contains("com.apple.Safari"))
        XCTAssertTrue(AppCatalog.chromiumBundles.contains("company.thebrowser.Browser"))
    }

    func testReadableBrowsersKeepTheirOrder() {
        XCTAssertEqual(AppCatalog.readableBrowsers.map(\.name), ["Safari", "Google Chrome", "Microsoft Edge", "Brave Browser", "Arc"])
    }

    func testCallHelpersCount() {
        XCTAssertTrue(AppCatalog.isCallApp("us.zoom.xos"))
        XCTAssertTrue(AppCatalog.isCallApp("us.zoom.xos.helper"))
        XCTAssertFalse(AppCatalog.isCallApp("us.zoom.xosx"))
    }

    func testReplyAppsAreChatAndMail() {
        XCTAssertTrue(AppCatalog.replyBundles.contains("com.microsoft.Outlook"))
        XCTAssertTrue(AppCatalog.replyBundles.contains("org.telegram.desktop"))
        XCTAssertTrue(DoubleTapLogic.replyApps == AppCatalog.replyBundles)
    }

    func testLooseKindsByName() {
        XCTAssertEqual(AppCatalog.kind(app: "Ghostty", bundleID: "com.mitchellh.ghostty"), .terminal)
        XCTAssertEqual(AppCatalog.kind(app: "Mail", bundleID: "com.apple.mail"), .mail)
        XCTAssertEqual(AppCatalog.kind(app: "Cursor", bundleID: "com.todesktop.cursor"), .editor)
        XCTAssertNil(AppCatalog.kind(app: "Something", bundleID: "com.example.thing"))
    }

    func testQuietModeReadsTheCatalog() {
        XCTAssertEqual(QuietPolicy.callApps, AppCatalog.callBundles)
        XCTAssertTrue(QuietPolicy.isBrowser("org.mozilla.firefox"))
    }
}
