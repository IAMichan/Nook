import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The phone's device key (`packages/protocol/Sources/CompanionDeviceKey.swift`) and the signature the seal carries next to
/// the ciphertext (`CompanionSeal` field `g`). CryptoKit: on the Mac only.
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

    func testWithoutASignatureTheEnvelopeIsAsBefore() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try sealed()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["d", "s"], "nothing new is added to an unsigned envelope")
    }
    #endif
}
