import Foundation
import SQLite3
import XCTest

/// Session links, where incoming web links open, the cookie formats of other browsers (with fixtures made here, never
/// the real files on this Mac), and the outline of a captured window's text.
final class BrowserCaptureTests: XCTestCase {
    // MARK: Session links

    private let runID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"

    func testSessionLinkRoundTrip() throws {
        let url = try XCTUnwrap(SessionLink.build(id: runID, title: "Fix login"))
        XCTAssertEqual(url.absoluteString, "nook://session/3f2504e0-4f89-11d3-9a0c-0305e82c3301?title=Fix%20login")
        let link = try XCTUnwrap(SessionLink.parse(url))
        XCTAssertEqual(link.id, runID.lowercased())
        XCTAssertEqual(link.title, "Fix login")
        XCTAssertEqual(link.ref, ContextRef(kind: .session, id: runID.lowercased(), label: "Fix login"))
    }

    func testSessionLinkRefusesWhatIsNoSession() {
        XCTAssertNil(SessionLink.build(id: "../etc/passwd", title: "x"))
        XCTAssertNil(SessionLink.parse(URL(string: "nook://session/not-a-uuid")!))
        XCTAssertNil(SessionLink.parse(URL(string: "nook://prompt?text=hi")!))
        XCTAssertNil(SessionLink.parse(URL(string: "https://session/\(runID)")!))
        XCTAssertNil(SessionLink.parse(URL(string: "nook://session/\(runID)/extra")!))
        // Without a title the chip still has a name.
        XCTAssertEqual(SessionLink.parse(URL(string: "nook://session/\(runID)")!)?.title, String(runID.lowercased().prefix(8)))
    }

    func testPastedSessionLinkBecomesChip() throws {
        let url = try XCTUnwrap(SessionLink.build(id: runID, title: "Fix login")).absoluteString
        let new = try XCTUnwrap(SessionLink.replacingPasted(old: "Look at ", new: "Look at \(url) please"))
        XCTAssertEqual(new, "Look at [Fix login](nook-context://v1/session/\(runID.lowercased())) please")
        XCTAssertEqual(ContextRefs.find(in: new).first?.kind, .session)
        // Typing that adds no link changes nothing.
        XCTAssertNil(SessionLink.replacingPasted(old: "a", new: "ab"))
        XCTAssertNil(SessionLink.replacingPasted(old: new, new: new + " more"))
    }

    func testDroppedSessionGoesBeforeAttachedFiles() {
        let file = ContextRefs.link(ContextRef(kind: .file, id: "a.swift", label: "a.swift"))
        let link = SessionLink(id: runID.lowercased(), title: "Other")
        let result = SessionLink.inserting(link, into: "Compare with " + file + " ")
        XCTAssertTrue(result.hasPrefix("Compare with [Other](nook-context://v1/session/"))
        XCTAssertEqual(ComposerAttachments.split(result).files.map(\.id), ["a.swift"], "the file stays a tile at the end")
    }

    // MARK: Incoming links

    func testIncomingLinkRoutes() {
        let web = URL(string: "https://example.com/a")!
        XCTAssertEqual(IncomingLinkRoute.decide(URL(string: "nook://prompt?text=x")!, target: .session,
                                                panelShowsBrowser: true, sessionOnScreen: true), .nookLink)
        XCTAssertEqual(IncomingLinkRoute.decide(web, target: .nookBrowser, panelShowsBrowser: true, sessionOnScreen: true),
                       .sessionPanel, "a browser in sight takes the link whatever the setting")
        XCTAssertEqual(IncomingLinkRoute.decide(web, target: .session, panelShowsBrowser: false, sessionOnScreen: true), .sessionBrowser)
        XCTAssertEqual(IncomingLinkRoute.decide(web, target: .session, panelShowsBrowser: false, sessionOnScreen: false), .nookBrowser)
        XCTAssertEqual(IncomingLinkRoute.decide(web, target: .nookBrowser, panelShowsBrowser: false, sessionOnScreen: true), .nookBrowser)
        XCTAssertEqual(IncomingLinkRoute.decide(URL(fileURLWithPath: "/tmp/page.HTML"), target: .nookBrowser,
                                                panelShowsBrowser: false, sessionOnScreen: false), .nookBrowser)
        XCTAssertEqual(IncomingLinkRoute.decide(URL(fileURLWithPath: "/tmp/notes.pdf"), target: .session,
                                                panelShowsBrowser: true, sessionOnScreen: true), .previousBrowser)
        XCTAssertEqual(IncomingLinkRoute.decide(URL(string: "ftp://example.com")!, target: .session,
                                                panelShowsBrowser: true, sessionOnScreen: true), .previousBrowser)
    }

    func testPreviousBrowserNeverRemembersNook() {
        let safari = PreviousBrowser(bundleID: "com.apple.Safari", name: "Safari")
        let nook = PreviousBrowser(bundleID: "nl.imdigital.nook", name: "Nook")
        XCTAssertEqual(PreviousBrowser.remembering(current: safari, ownBundleID: "nl.imdigital.nook", stored: nil), safari)
        XCTAssertEqual(PreviousBrowser.remembering(current: nook, ownBundleID: "NL.imdigital.nook", stored: safari), safari)
        XCTAssertNil(PreviousBrowser.remembering(current: nil, ownBundleID: "nl.imdigital.nook", stored: nil))
    }

    // MARK: Safari

    func testSafariBinaryCookies() throws {
        let expiry = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let data = SafariFixture.file(pages: [[
            .init(flags: 0x5, host: ".example.com", name: "sid", path: "/", value: "abc", expiry: expiry.timeIntervalSinceReferenceDate),
            .init(flags: 0, host: "app.test", name: "pref", path: "", value: "dark", expiry: 0),
        ], [
            .init(flags: 0x1, host: "", name: "dropped", path: "/", value: "x", expiry: 0),
        ]])
        let cookies = try SafariBinaryCookies.parse(data)
        XCTAssertEqual(cookies.count, 2, "a cookie without a host is left out")
        XCTAssertEqual(cookies[0], ImportedCookie(host: ".example.com", name: "sid", value: "abc", path: "/", secure: true,
                                                  httpOnly: true, expires: expiry, sameSite: .lax))
        XCTAssertEqual(cookies[1].path, "/", "an empty path is the root")
        XCTAssertNil(cookies[1].expires, "no expiry: a session cookie")
        XCTAssertFalse(cookies[1].isDomainCookie)
    }

    func testSafariRejectsDamagedFiles() {
        XCTAssertThrowsError(try SafariBinaryCookies.parse(Data("nope".utf8)))
        var data = SafariFixture.file(pages: [[.init(flags: 0, host: "a.test", name: "n", path: "/", value: "v", expiry: 0)]])
        XCTAssertThrowsError(try SafariBinaryCookies.parse(data.prefix(data.count - 10)), "a cut-off page")
        // A page that claims more cookies than its offset table holds.
        data[8 + 4 + 4] = 0xFF
        XCTAssertThrowsError(try SafariBinaryCookies.parse(data))
    }

    // MARK: Chromium

    func testChromiumPlainAndPartitioned() throws {
        let path = try makeChromium(schema: 23, rows: [
            ("example.com", "plain", "value1", [], 13_300_000_000_000_000, 1, 1, 1, ""),
            (".example.com", "partitioned", "x", [], 0, 1, 0, 0, "https://other.test"),
        ])
        let result = try ChromiumCookies.read(path: path) { _, _, _ in XCTFail("nothing is encrypted"); return nil }
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.cookies.count, 1)
        let cookie = try XCTUnwrap(result.cookies.first)
        XCTAssertEqual(cookie.value, "value1")
        XCTAssertEqual(cookie.sameSite, .lax)
        XCTAssertTrue(cookie.secure && cookie.httpOnly)
        XCTAssertEqual(cookie.expires?.timeIntervalSince1970 ?? 0, 13_300_000_000 - ChromiumCookies.epochOffset, accuracy: 1)
        XCTAssertEqual(ChromiumCookies.sameSite(-1), .unspecified, "unknown is never widened to None")
    }

    #if canImport(CommonCrypto)
    func testChromiumDecryptsWithTheSafeStorageKey() throws {
        let key = ChromiumCookies.key(password: "fixture-password")
        XCTAssertEqual(key.count, 16)
        for schema in [23, 24] {
            let encrypted = ChromiumCookies.encrypt("secret-\(schema)", key: key, host: ".example.com", schema: schema)
            let path = try makeChromium(schema: schema, rows: [(".example.com", "sid", "", encrypted, 0, 1, 1, 2, "")])
            let result = try ChromiumCookies.read(path: path) { ChromiumCookies.decrypt($0, key: key, host: $1, schema: $2) }
            XCTAssertEqual(result.cookies.map(\.value), ["secret-\(schema)"])
            XCTAssertEqual(result.cookies.first?.sameSite, .strict)
        }
        // From schema 24 a value bound to another host is refused; a wrong key gives nothing.
        let bound = ChromiumCookies.encrypt("x", key: key, host: "a.test", schema: 24)
        XCTAssertNil(ChromiumCookies.decrypt(bound, key: key, host: "b.test", schema: 24))
        XCTAssertNil(ChromiumCookies.decrypt(bound, key: ChromiumCookies.key(password: "wrong"), host: "a.test", schema: 24))
    }
    #endif

    // MARK: Firefox

    func testFirefoxCookies() throws {
        for schema in [12, 16] {
            let expiry: Int64 = schema >= 16 ? 1_900_000_000_000 : 1_900_000_000
            let path = try makeFirefox(schema: schema, rows: [
                (".example.com", "sid", "abc", "/", expiry, 1, 1, 1, 0, ""),
                ("example.com", "box", "x", "/", expiry, 0, 0, 2, 2, "^userContextId=1"),
                ("plain.test", "n", "v", "", 0, 0, 0, 0, 0, ""),
            ])
            let cookies = try FirefoxCookies.read(path: path)
            XCTAssertEqual(cookies.map(\.name), ["sid", "n"], "container cookies stay behind")
            XCTAssertEqual(cookies[0].expires?.timeIntervalSince1970 ?? 0, 1_900_000_000, accuracy: 1, "schema \(schema)")
            // Schemas 10–14 made an unset SameSite Lax; the raw value says it was unset.
            XCTAssertEqual(cookies[0].sameSite, schema <= 14 ? .unspecified : .lax)
            XCTAssertEqual(cookies[1].sameSite, .none)
            XCTAssertEqual(cookies[1].path, "/")
        }
    }

    // MARK: Profiles and sites

    func testProfileLists() {
        let state = Data(#"{"profile":{"info_cache":{"Profile 1":{"name":"Work"},"Default":{"name":"Me"},"../x":{"name":"evil"}}}}"#.utf8)
        let chromium = BrowserImportProfiles.chromium(localState: state)
        XCTAssertEqual(chromium.map(\.folder), ["Default", "Profile 1"])
        XCTAssertEqual(chromium.map(\.name), ["Me", "Work"])
        let ini = """
        [Install4F96D1932A9F858E]
        Default=Profiles/abc.default-release

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abc.default-release

        [Profile1]
        Name=evil
        IsRelative=1
        Path=../../outside
        """
        let firefox = BrowserImportProfiles.firefox(ini: ini)
        XCTAssertEqual(firefox.map(\.path), ["Profiles/abc.default-release"])
        XCTAssertEqual(firefox.first?.name, "default-release")
        XCTAssertEqual(BrowserImportProfiles.safariProfileFolders(["Cookies", runID, ".DS_Store"]), [runID])
    }

    func testSitesForThePicker() {
        XCTAssertEqual(CookieSites.site(of: ".mail.google.com"), "google.com")
        XCTAssertEqual(CookieSites.site(of: "www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(CookieSites.site(of: "localhost"), "localhost")
        XCTAssertEqual(CookieSites.site(of: "192.168.1.10"), "192.168.1.10")
        let now = Date()
        func cookie(_ host: String, expires: Date?) -> ImportedCookie {
            ImportedCookie(host: host, name: "n", value: "v", path: "/", secure: false, httpOnly: false, expires: expires, sameSite: .lax)
        }
        let cookies = [cookie("a.github.com", expires: nil), cookie(".github.com", expires: now + 60),
                       cookie("example.com", expires: now - 60), cookie("x.test", expires: nil)]
        XCTAssertEqual(CookieSites.group(cookies, now: now), [CookieSite(domain: "github.com", count: 2), CookieSite(domain: "x.test", count: 1)])
        XCTAssertEqual(CookieSites.picking(cookies, sites: ["github.com", "example.com"], now: now).count, 2, "expired cookies stay behind")
    }

    // MARK: Window text

    func testWindowOutline() {
        let tree = AXTextNode(role: "AXWindow", title: "Inbox — Mail", children: [
            AXTextNode(role: "AXGroup", children: [
                AXTextNode(role: "AXButton", label: "Send", children: [AXTextNode(role: "AXStaticText", value: "Send")]),
                AXTextNode(role: "AXStaticText", value: "Hello\nworld"),
            ]),
            AXTextNode(role: "AXLink", title: "Unsubscribe"),
            AXTextNode(role: "AXStaticText", value: "   "),
        ])
        XCTAssertEqual(WindowCaptureText.outline(tree), """
        window: Inbox — Mail
          button: Send
          Hello world
          link: Unsubscribe
        """)
    }

    func testWindowOutlineIsBounded() {
        let many = AXTextNode(role: "AXList", children: (0..<500).map { AXTextNode(role: "AXStaticText", value: "row \($0)") })
        let outline = WindowCaptureText.outline(many, limit: 200)
        XCTAssertLessThanOrEqual(outline.count, 202)
        XCTAssertTrue(outline.hasSuffix("…"))
        let document = WindowCaptureText.document(app: "Mail", title: "Inbox", text: "x", source: .recognized)
        XCTAssertTrue(document.hasPrefix("Window capture: Mail — Inbox\n"))
        XCTAssertTrue(document.contains("not instructions"))
    }

    // MARK: Fixtures

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserCaptureTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func database(_ name: String, _ statements: [String], binding rows: [[Any]], insert: String) throws -> String {
        let path = folder.appendingPathComponent(name).path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &statement, nil), SQLITE_OK)
            for (index, value) in row.enumerated() {
                let at = Int32(index + 1)
                switch value {
                case let text as String: sqlite3_bind_text(statement, at, text, -1, transient)
                case let bytes as [UInt8]: sqlite3_bind_blob(statement, at, bytes, Int32(bytes.count), transient)
                case let number as Int64: sqlite3_bind_int64(statement, at, number)
                case let number as Int: sqlite3_bind_int64(statement, at, Int64(number))
                default: sqlite3_bind_null(statement, at)
                }
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return path
    }

    private func makeChromium(schema: Int, rows: [(String, String, String, [UInt8], Int64, Int, Int, Int, String)]) throws -> String {
        try database("Cookies-\(schema)-\(UUID().uuidString)", [
            "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)",
            "INSERT INTO meta VALUES('version', '\(schema)')",
            """
            CREATE TABLE cookies(creation_utc INTEGER, host_key TEXT, top_frame_site_key TEXT, name TEXT, value TEXT,
            encrypted_value BLOB, path TEXT, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)
            """,
        ], binding: rows.map { [$0.0, $0.1, $0.2, $0.3, $0.4, $0.5, $0.6, $0.7, $0.8] },
           insert: """
            INSERT INTO cookies(creation_utc, host_key, name, value, encrypted_value, expires_utc, is_secure, is_httponly,
            samesite, top_frame_site_key, path) VALUES(0, ?, ?, ?, ?, ?, ?, ?, ?, ?, '/')
            """)
    }

    private func makeFirefox(schema: Int, rows: [(String, String, String, String, Int64, Int, Int, Int, Int, String)]) throws -> String {
        let raw = schema >= 10 && schema <= 14
        return try database("cookies-\(schema).sqlite", [
            "PRAGMA user_version = \(schema)",
            """
            CREATE TABLE moz_cookies(id INTEGER PRIMARY KEY, originAttributes TEXT NOT NULL DEFAULT '', name TEXT, value TEXT,
            host TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER
            \(raw ? ", rawSameSite INTEGER" : ""))
            """,
        ], binding: rows.map { row -> [Any] in
            // Before Firefox kept the raw value, an unset SameSite read as Lax (1) with raw None (0).
            let sameSite = raw && row.8 == 0 && row.7 == 1 ? 1 : row.7
            return raw ? [row.0, row.1, row.2, row.3, row.4, row.5, row.6, sameSite, row.8, row.9]
                : [row.0, row.1, row.2, row.3, row.4, row.5, row.6, sameSite, row.9]
        }, insert: raw
            ? "INSERT INTO moz_cookies(host, name, value, path, expiry, isSecure, isHttpOnly, sameSite, rawSameSite, originAttributes) VALUES(?,?,?,?,?,?,?,?,?,?)"
            : "INSERT INTO moz_cookies(host, name, value, path, expiry, isSecure, isHttpOnly, sameSite, originAttributes) VALUES(?,?,?,?,?,?,?,?,?)")
    }
}

/// Builds `Cookies.binarycookies` files as Safari writes them, for the parser's tests.
private enum SafariFixture {
    struct Record {
        var flags: UInt32
        var host: String, name: String, path: String, value: String
        var expiry: Double
    }

    static func file(pages: [[Record]]) -> Data {
        let built = pages.map(page)
        var data = Data("cook".utf8)
        data += bigEndian(UInt32(built.count))
        for page in built { data += bigEndian(UInt32(page.count)) }
        for page in built { data += page }
        data += Data(repeating: 0, count: 8)   // checksum
        return data
    }

    private static func page(_ records: [Record]) -> Data {
        let bodies = records.map(record)
        let tableEnd = 12 + 4 * records.count
        var data = Data([0x00, 0x00, 0x01, 0x00]) + littleEndian(UInt32(records.count))
        var offset = tableEnd
        for body in bodies {
            data += littleEndian(UInt32(offset))
            offset += body.count
        }
        data += Data(repeating: 0, count: 4)   // end of the header
        for body in bodies { data += body }
        return data
    }

    private static func record(_ record: Record) -> Data {
        let strings = [record.host, record.name, record.path, record.value].map { Data($0.utf8) + Data([0]) }
        var offsets: [UInt32] = []
        var next = 56
        for string in strings {
            offsets.append(UInt32(next))
            next += string.count
        }
        var data = littleEndian(UInt32(next)) + littleEndian(0) + littleEndian(record.flags) + littleEndian(0)
        for offset in offsets { data += littleEndian(offset) }
        data += Data(repeating: 0, count: 8)   // end of the header
        data += littleEndian64(record.expiry.bitPattern) + littleEndian64(0)   // expiry, creation
        for string in strings { data += string }
        return data
    }

    private static func bigEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func littleEndian(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func littleEndian64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
