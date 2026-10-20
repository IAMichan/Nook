import XCTest

/// What an external brain gets at each privacy level: secrets out from Balanced on, contact details out at Strict, and
/// the identifiers a model still acts on (event ids, commit hashes) left alone.
final class PrivacyFilterTests: XCTestCase {
    private let secrets = "Kaart 4111 1111 1111 1111, IBAN NL91 ABNA 0417 1643 00, BSN 111222333, wachtwoord: hunter2, sk-proj-abcdefghijklmnopqrstuvwx"

    func testOpenChangesNothing() {
        XCTAssertEqual(PrivacyFilter.apply(secrets, level: .open), secrets)
    }

    func testBalancedTakesOutSecrets() {
        let clean = PrivacyFilter.apply(secrets, level: .balanced)
        for secret in ["4111", "ABNA", "111222333", "hunter2", "sk-proj"] {
            XCTAssertFalse(clean.contains(secret), secret)
        }
        XCTAssertTrue(clean.hasPrefix("Kaart [redacted]"))
    }

    func testBalancedKeepsContactDetails() {
        let text = "Mail anna@example.com of bel 06-12345678."
        XCTAssertEqual(PrivacyFilter.apply(text, level: .balanced), text)
    }

    func testStrictTakesOutContactDetails() {
        let clean = PrivacyFilter.apply("Mail anna.de.vries@example.co.uk, bel 06-12345678, +31 20 123 4567 of 020 123 4567.", level: .strict)
        XCTAssertEqual(clean, "Mail [email], bel [phone], [phone] of [phone].")
    }

    func testStrictTakesOutRandomTokens() {
        let clean = PrivacyFilter.apply("key Zx81kQ2pLm7Rt5Vw9Yb3Nc6Hd4Jf0Gs1", level: .strict)
        XCTAssertEqual(clean, "key [redacted]")
    }

    func testIdentifiersStayAtEveryLevel() {
        let text = "event E621E1F8-C36C-495A-93FC-0C247A3E6E5F, commit 3f9c2a7b1d4e5f60718293a4b5c6d7e8f9012345"
        for level in PrivacyLevel.allCases {
            XCTAssertEqual(PrivacyFilter.apply(text, level: level), text, level.rawValue)
        }
    }

    func testDatesTimesAndOffsetsStay() {
        let text = "Nu: 2026-10-20T09:30:00+02:00, om 10:30 in kamer 12"
        XCTAssertEqual(PrivacyFilter.apply(text, level: .strict), text)
    }

    func testStrictKeepsScreenAndClipboardOnTheMac() {
        XCTAssertEqual(PrivacyLevel.strict.localOnlySources, [SourceCatalog.screen, "clipboard"])
        XCTAssertTrue(PrivacyLevel.balanced.localOnlySources.isEmpty)
        XCTAssertTrue(PrivacyLevel.open.localOnlySources.isEmpty)
    }

    func testWritingSamplesStillDropLongTokens() {
        // Autocomplete keeps its broader rule: a long key without a known prefix never becomes a writing sample.
        XCTAssertEqual(CompletionPrivacy.sanitize("abc1234567890abcdef1234567890abcdef"), "[redacted]")
        XCTAssertEqual(CompletionPrivacy.sanitize("abc1234567890abcdef1234567890abcdef", generic: false), "abc1234567890abcdef1234567890abcdef")
    }
}
