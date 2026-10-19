import XCTest

final class WebhookSecurityTests: XCTestCase {
    private func hex(_ s: String) -> String { WebhookHex.encode(PureSHA256.hash(Data(s.utf8))) }

    // MARK: SHA-256 (FIPS 180-4)

    func testSHA256Vectors() {
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(WebhookHex.encode(PureSHA256.hash(Data(repeating: 0x61, count: 1_000_000))),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testSHA256PaddingBoundaries() {
        // 55, 56 and 64 bytes straddle the length-field padding.
        XCTAssertEqual(hex(String(repeating: "a", count: 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(hex(String(repeating: "a", count: 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        XCTAssertEqual(hex(String(repeating: "a", count: 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    // MARK: HMAC (RFC 4231)

    func testHMACVectors() {
        let case1 = PureHMAC.sha256(key: Data(repeating: 0x0b, count: 20), message: Data("Hi There".utf8))
        XCTAssertEqual(WebhookHex.encode(case1), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        let case2 = PureHMAC.sha256(key: Data("Jefe".utf8), message: Data("what do ya want for nothing?".utf8))
        XCTAssertEqual(WebhookHex.encode(case2), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // Key longer than the block size is hashed first (test case 6).
        let case6 = PureHMAC.sha256(key: Data(repeating: 0xaa, count: 131),
                                    message: Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8))
        XCTAssertEqual(WebhookHex.encode(case6), "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    // MARK: Verifier

    func testVerifyAcceptsPrefixedAndBareHexAnyCase() {
        let body = Data(#"{"a":1}"#.utf8)
        let sig = WebhookVerifier.signature(secret: "s3cret", body: body)
        XCTAssertTrue(WebhookVerifier.verify(secret: "s3cret", body: body, signatureHeader: sig))
        XCTAssertTrue(WebhookVerifier.verify(secret: "s3cret", body: body, signatureHeader: String(sig.dropFirst(7))))
        XCTAssertTrue(WebhookVerifier.verify(secret: "s3cret", body: body, signatureHeader: " " + sig.uppercased() + "\n"))
        XCTAssertTrue(WebhookVerifier.verify(secret: "s3cret", body: body, signatureHeader: "SHA256=" + String(sig.dropFirst(7)).uppercased()))
    }

    func testVerifyRejectsWrongInputs() {
        let body = Data("payload".utf8)
        let sig = WebhookVerifier.signature(secret: "k", body: body)
        XCTAssertFalse(WebhookVerifier.verify(secret: "other", body: body, signatureHeader: sig))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: Data("payload!".utf8), signatureHeader: sig))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: body, signatureHeader: nil))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: body, signatureHeader: ""))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: body, signatureHeader: "sha256="))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: body, signatureHeader: "sha256=zz"))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: body, signatureHeader: String(sig.dropLast(2))))
        XCTAssertFalse(WebhookVerifier.verify(secret: "", body: body, signatureHeader: sig))
    }

    func testSignatureOfEmptyBody() {
        let sig = WebhookVerifier.signature(secret: "k", body: Data())
        XCTAssertTrue(WebhookVerifier.verify(secret: "k", body: Data(), signatureHeader: sig))
        XCTAssertFalse(WebhookVerifier.verify(secret: "k", body: Data("x".utf8), signatureHeader: sig))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(WebhookVerifier.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertTrue(WebhookVerifier.constantTimeEqual(Data(), Data()))
        XCTAssertFalse(WebhookVerifier.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(WebhookVerifier.constantTimeEqual(Data([1, 2]), Data([1, 2, 0])))
        XCTAssertFalse(WebhookVerifier.constantTimeEqual(Data(), Data([0])))
    }

    // MARK: Delivery log, rate window

    func testDeliveryLogRejectsReplayAndForgetsOldest() {
        var log = DeliveryLog(capacity: 2)
        XCTAssertTrue(log.record("a"))
        XCTAssertFalse(log.record("a"))
        XCTAssertTrue(log.record("b"))
        XCTAssertTrue(log.record("c"))
        XCTAssertFalse(log.contains("a"))
        XCTAssertTrue(log.record("a"), "forgotten after eviction")
        XCTAssertEqual(log.ids.count, 2)
    }

    func testDeliveryLogRoundTrips() throws {
        var log = DeliveryLog(capacity: 3)
        _ = log.record("x")
        let back = try JSONDecoder().decode(DeliveryLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(back, log)
        XCTAssertFalse({ var b = back; return b.record("x") }())
    }

    func testRateWindowLimitsAndRecovers() {
        var w = RateWindow(limit: 2, window: 60)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(w.admit(now: t0), .accepted)
        XCTAssertEqual(w.admit(now: t0.addingTimeInterval(10)), .accepted)
        XCTAssertEqual(w.admit(now: t0.addingTimeInterval(20)), .limited(first: true))
        XCTAssertEqual(w.admit(now: t0.addingTimeInterval(30)), .limited(first: false))
        XCTAssertEqual(w.admit(now: t0.addingTimeInterval(61)), .accepted, "first one left the window")
        XCTAssertEqual(w.admit(now: t0.addingTimeInterval(62)), .limited(first: true), "full again; logged again in a new burst")
        XCTAssertEqual(w.admit(now: t0.addingTimeInterval(200)), .accepted, "everything aged out")
    }

    func testRateWindowDefaults() {
        XCTAssertEqual(RateWindow().limit, 60)
        XCTAssertEqual(RateWindow().window, 60)
    }
}
