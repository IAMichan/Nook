import Foundation
import CryptoKit

/// Sealing of companion messages: ChaCha20-Poly1305 with a key derived (HKDF-SHA256) from the pairing key. The device id
/// and the direction are authenticated too, so a request cannot be replayed to the phone as an answer, or the other way round.
/// An envelope is `{"d": "<device id>", "s": "<base64 nonce+ciphertext+tag>"}`, with two optional fields:
///
/// - `z`: the plaintext was compressed before sealing (`CompanionDeflate.name`). It is authenticated too (it joins the
///   associated data), so it cannot be added or taken away on the way. An envelope without it is read as before.
/// - `g`: a request's signature by the phone's own device key (`CompanionDeviceKey`) over `d|s`, for a Mac that holds the
///   key's public half. Outside the seal, as the seal is what it signs.
enum CompanionSeal {
    enum Direction: String { case request = "q", response = "r" }

    struct Envelope: Codable {
        var d: String
        var s: String
        var z: String? = nil
        var g: String? = nil
    }

    enum Failure: Error { case malformed, authentication }

    private static func symmetricKey(_ pairingKey: Data) -> SymmetricKey {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: pairingKey), salt: Data("nook-companion".utf8),
                                             info: Data("v1".utf8), outputByteCount: 32)
        return derived
    }

    private static func aad(_ deviceID: String, _ direction: Direction, compression: String? = nil) -> Data {
        guard let compression else { return Data((deviceID + "|" + direction.rawValue).utf8) }
        return Data((deviceID + "|" + direction.rawValue + "|" + compression).utf8)
    }

    /// With `compress`, a plaintext large enough to gain from it is compressed first (`CompanionDeflate`); only for a
    /// reader that said it can read that.
    static func seal(_ plaintext: Data, pairingKey: Data, deviceID: String, direction: Direction, compress: Bool = false) throws -> Data {
        let packed = compress ? CompanionDeflate.compress(plaintext) : nil
        let compression = packed == nil ? nil : CompanionDeflate.name
        let box = try ChaChaPoly.seal(packed ?? plaintext, using: symmetricKey(pairingKey),
                                      authenticating: aad(deviceID, direction, compression: compression))
        return try JSONEncoder().encode(Envelope(d: deviceID, s: box.combined.base64EncodedString(), z: compression))
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
        // Only a compression this build reads; anything else is not a message for it.
        if let compression = parsed.z, compression != CompanionDeflate.name { throw Failure.malformed }
        let opened: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            opened = try ChaChaPoly.open(box, using: symmetricKey(pairingKey), authenticating: aad(parsed.d, direction, compression: parsed.z))
        } catch {
            throw Failure.authentication
        }
        guard parsed.z != nil else { return opened }
        guard let inflated = CompanionDeflate.decompress(opened) else { throw Failure.malformed }
        return inflated
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
