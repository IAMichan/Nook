import Foundation
import CryptoKit

/// Sealing of companion messages: ChaCha20-Poly1305 with a key derived (HKDF-SHA256) from the pairing key. The device id
/// and the direction are authenticated too, so a request cannot be replayed to the phone as an answer, or the other way round.
/// An envelope is `{"d": "<device id>", "s": "<base64 nonce+ciphertext+tag>"}`, and for a request to a Mac that holds the
/// phone's device key `"g"`: its signature by that key (`CompanionDeviceKey`) over `d|s`, outside the seal, as the seal
/// is what it signs. An envelope without it reads as before.
enum CompanionSeal {
    enum Direction: String { case request = "q", response = "r" }

    struct Envelope: Codable {
        var d: String
        var s: String
        var g: String? = nil
    }

    enum Failure: Error { case malformed, authentication }

    private static func symmetricKey(_ pairingKey: Data) -> SymmetricKey {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pairingKey), salt: Data("nook-companion".utf8),
                                             info: Data("v1".utf8), outputByteCount: 32)
        return derived
    }

    private static func aad(_ deviceID: String, _ direction: Direction) -> Data { Data((deviceID + "|" + direction.rawValue).utf8) }

    static func seal(_ plaintext: Data, pairingKey: Data, deviceID: String, direction: Direction) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: symmetricKey(pairingKey), authenticating: aad(deviceID, direction))
        return try JSONEncoder().encode(Envelope(d: deviceID, s: box.combined.base64EncodedString()))
    }

    /// With a fixed nonce: only for the shared test vectors (`packages/protocol/Fixtures/sealed.json`). A nonce must never
    /// be used twice with the same key.
    static func seal(_ plaintext: Data, pairingKey: Data, deviceID: String, direction: Direction, nonce: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: symmetricKey(pairingKey), nonce: ChaChaPoly.Nonce(data: nonce),
                                      authenticating: aad(deviceID, direction))
        return try JSONEncoder().encode(Envelope(d: deviceID, s: box.combined.base64EncodedString()))
    }

    /// The device id an envelope claims, to pick the key to try. Not trusted until `open` succeeds.
    static func claimedDevice(_ envelope: Data) -> String? {
        (try? JSONDecoder().decode(Envelope.self, from: envelope))?.d
    }

    static func open(_ envelope: Data, pairingKey: Data, direction: Direction) throws -> Data {
        guard let parsed = try? JSONDecoder().decode(Envelope.self, from: envelope),
              let combined = Data(base64Encoded: parsed.s), combined.count > 28 else { throw Failure.malformed }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(box, using: symmetricKey(pairingKey), authenticating: aad(parsed.d, direction))
        } catch {
            throw Failure.authentication
        }
    }

    // MARK: Device signatures

    /// What a device key signs for an envelope: its device id and sealed bytes. Nil when it is not an envelope.
    static func signedBytes(_ envelope: Data) -> Data? {
        guard let parsed = try? JSONDecoder().decode(Envelope.self, from: envelope) else { return nil }
        return Data((parsed.d + "|" + parsed.s).utf8)
    }

    /// The envelope with `signature` added (`g`).
    static func attach(signature: Data, to envelope: Data) -> Data? {
        guard var parsed = try? JSONDecoder().decode(Envelope.self, from: envelope) else { return nil }
        parsed.g = signature.base64EncodedString()
        return try? JSONEncoder().encode(parsed)
    }

    /// The signature an envelope carries, if any.
    static func signature(_ envelope: Data) -> Data? {
        guard let parsed = try? JSONDecoder().decode(Envelope.self, from: envelope), let g = parsed.g else { return nil }
        return Data(base64Encoded: g)
    }
}
