import Foundation
import CryptoKit

/// Sealing of companion messages: ChaCha20-Poly1305 with a key derived (HKDF-SHA256) from the pairing key. The device id
/// and the direction are authenticated too, so a request cannot be replayed to the phone as an answer, or the other way round.
/// An envelope is `{"d": "<device id>", "s": "<base64 nonce+ciphertext+tag>"}`.
enum CompanionSeal {
    enum Direction: String { case request = "q", response = "r" }

    struct Envelope: Codable {
        var d: String
        var s: String
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
}
