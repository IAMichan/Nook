import XCTest

/// The local companion diagnostics log (`CompanionDiagnosticsLog`) and what *Copy diagnostics* leaves out (`CompanionRedaction`).
final class CompanionDiagnosticsLogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-companion-log-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testEventsAreWrittenAsLinesAndReadBack() throws {
        let log = CompanionDiagnosticsLog(url: folder.appendingPathComponent("companion.ndjson"))
        log.record("route", ["kind": "lan", "ms": "42"], now: Date(timeIntervalSince1970: 100))
        log.record("closed", ["code": "4404"], now: Date(timeIntervalSince1970: 101))
        let events = log.events()
        XCTAssertEqual(events.map(\.event), ["route", "closed"])
        XCTAssertEqual(events.first?.fields["ms"], "42")
        XCTAssertEqual(events.first?.at, 100)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2, "one JSON object per line")
        log.clear()
        XCTAssertEqual(log.events(), [])
    }

    func testTheLogRotatesAndStaysBounded() throws {
        let log = CompanionDiagnosticsLog(url: folder.appendingPathComponent("companion.ndjson"), maxBytes: 2048)
        for i in 0..<200 { log.record("probe", ["route": "\(i)", "pad": String(repeating: "x", count: 40)]) }
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0 }
        XCTAssertLessThanOrEqual(size(log.url), 2048)
        XCTAssertLessThanOrEqual(size(log.olderURL), 2048)
        let events = log.events()
        XCTAssertLessThan(events.count, 200, "the oldest are gone")
        XCTAssertEqual(events.last?.fields["route"], "199", "the newest stay")
    }

    func testValuesAreCut() {
        let log = CompanionDiagnosticsLog(url: folder.appendingPathComponent("companion.ndjson"))
        log.record("error", ["message": String(repeating: "a", count: 1000)])
        XCTAssertEqual(log.events().first?.fields["message"]?.count, 300)
    }

    func testRedactionRemovesAddressesNamesAndKeys() {
        let line = #"{"host":"192.168.1.20","tailnet":"100.101.102.103","name":"Michaels-MacBook.local","relay":"https://nook-relay.me.workers.dev","room":"cae98fe2b67a6f65273aa18446bdf884","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","event":"companion_update_request","error":"notAllowedFromPhone"}"#
        let redacted = CompanionRedaction.redact(line)
        for secret in ["192.168", "100.101", "Michaels", "nook-relay", "cae98fe2", "AAECAwQF"] {
            XCTAssertFalse(redacted.contains(secret), "\(secret) in \(redacted)")
        }
        XCTAssertTrue(redacted.contains("<lan>"))
        XCTAssertTrue(redacted.contains("<vpn>"))
        XCTAssertTrue(redacted.contains("<host>.local"))
        XCTAssertTrue(redacted.contains("https://<relay>"))
        XCTAssertTrue(redacted.contains("companion_update_request"), "long words without digits stay")
        XCTAssertTrue(redacted.contains("notAllowedFromPhone"))
    }

    func testTheBundleIsRedactedWithAHeader() {
        let log = CompanionDiagnosticsLog(url: folder.appendingPathComponent("companion.ndjson"))
        log.record("route", ["host": "10.0.0.7", "relay": "https://relay.example.com/v1/rooms/cae98fe2b67a6f65273aa18446bdf884"])
        let bundle = log.bundle(about: ["app": "1.4.0", "mac": "studio.local"])
        XCTAssertTrue(bundle.hasPrefix("# Nook companion diagnostics"))
        XCTAssertTrue(bundle.contains("# app: 1.4.0"))
        XCTAssertTrue(bundle.contains("# mac: <host>.local"))
        XCTAssertFalse(bundle.contains("10.0.0.7"))
        XCTAssertFalse(bundle.contains("relay.example.com"))
        XCTAssertFalse(bundle.contains("cae98fe2"))
    }
}
