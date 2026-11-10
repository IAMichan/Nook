import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The phone's device key (`packages/protocol/Sources/CompanionDeviceKey.swift`) and what the seal carries besides the
/// ciphertext (`CompanionSeal`: `z` for compression, `g` for the signature). CryptoKit: on the Mac only.
final class CompanionDeviceKeyTests: XCTestCase {
    #if canImport(CryptoKit)
    private let pairingKey = Data(repeating: 7, count: 32)

    private func sealed(_ text: String = #"{"id":"r","sent":1,"op":"list"}"#) throws -> Data {
        try CompanionSeal.seal(Data(text.utf8), pairingKey: pairingKey, deviceID: "dev", direction: .request)
    }

    func testASignedEnvelopeVerifiesWithItsKeyOnly() throws {
        let key = P256.Signing.PrivateKey()
        let envelope = try sealed()
        let bytes = try XCTUnwrap(CompanionSeal.signedBytes(envelope))
        let signed = try XCTUnwrap(CompanionSeal.attach(signature: key.signature(for: bytes).rawRepresentation, to: envelope))
        XCTAssertTrue(CompanionDeviceKey.verify(envelope: signed, publicKey: key.publicKey.x963Representation))
        XCTAssertFalse(CompanionDeviceKey.verify(envelope: signed, publicKey: P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertFalse(CompanionDeviceKey.verify(envelope: envelope, publicKey: key.publicKey.x963Representation), "unsigned")
        // The signature does not get in the way of opening it.
        XCTAssertEqual(try CompanionSeal.open(signed, pairingKey: pairingKey, direction: .request), Data(#"{"id":"r","sent":1,"op":"list"}"#.utf8))
    }

    func testASignatureDoesNotCarryOverToAnotherMessage() throws {
        let key = P256.Signing.PrivateKey()
        let first = try sealed()
        let bytes = try XCTUnwrap(CompanionSeal.signedBytes(first))
        let signature = try key.signature(for: bytes).rawRepresentation
        let other = try XCTUnwrap(CompanionSeal.attach(signature: signature, to: try sealed(#"{"id":"x","sent":1,"op":"stop"}"#)))
        XCTAssertFalse(CompanionDeviceKey.verify(envelope: other, publicKey: key.publicKey.x963Representation))
    }

    func testOnlyAP256PublicKeyIsTakenAndPingNeedsNoSignature() {
        XCTAssertTrue(CompanionDeviceKey.isValidPublicKey(P256.Signing.PrivateKey().publicKey.x963Representation))
        XCTAssertFalse(CompanionDeviceKey.isValidPublicKey(Data(repeating: 1, count: 65)))
        XCTAssertFalse(CompanionDeviceKey.needsSignature(.ping))
        XCTAssertTrue(CompanionDeviceKey.needsSignature(.decide))
        XCTAssertTrue(CompanionDeviceKey.needsSignature(.bindKey))
    }

    func testCompressedSealOpensAndItsMarkCannotBeTakenAway() throws {
        try XCTSkipUnless(CompanionDeflate.isAvailable)
        let text = String(repeating: #"{"id":"e","kind":"assistant","text":"the same words again"},"#, count: 200)
        let envelope = try CompanionSeal.seal(Data(text.utf8), pairingKey: pairingKey, deviceID: "dev", direction: .response, compress: true)
        var parsed = try JSONDecoder().decode(CompanionSeal.Envelope.self, from: envelope)
        XCTAssertEqual(parsed.z, CompanionDeflate.name)
        XCTAssertEqual(try CompanionSeal.open(envelope, pairingKey: pairingKey, direction: .response), Data(text.utf8))
        parsed.z = nil
        XCTAssertThrowsError(try CompanionSeal.open(JSONEncoder().encode(parsed), pairingKey: pairingKey, direction: .response))
        parsed.z = "brotli"
        XCTAssertThrowsError(try CompanionSeal.open(JSONEncoder().encode(parsed), pairingKey: pairingKey, direction: .response))
    }

    func testWithoutCompressionTheEnvelopeIsAsBefore() throws {
        let envelope = try CompanionSeal.seal(Data("short".utf8), pairingKey: pairingKey, deviceID: "dev", direction: .request, compress: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["d", "s"], "a small message is not compressed, and nothing new is added")
    }
    #endif
}
