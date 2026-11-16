import Foundation
import CryptoKit

/// A phone's own signing key, next to the pairing key both sides share (docs/COMPANION.md, "Device key").
///
/// The pairing key seals every message; whoever holds a copy of it (a backup, a leaked file) could seal requests too. The
/// device key closes that: the phone makes a P-256 key that never leaves it (in the Secure Enclave where the phone has
/// one), tells a Mac that lists `CompanionFeature.deviceKey` its public half once (`CompanionOp.bindKey`), and from then
/// on signs every request (`CompanionSeal` envelope field `g`). The Mac refuses an unsigned or wrongly signed request from
/// that phone, except `ping` (which carries and returns nothing), so a copied pairing key alone can no longer act.
///
/// The first key a Mac hears for a pairing is the one it keeps (trust on first use): the phone binds it right after
/// pairing. Unpairing forgets it on both sides.
enum CompanionDeviceKey {
    /// The public half as the phone sends it: X9.63 (65 bytes, uncompressed), base64 in `CompanionRequest.text`.
    static func isValidPublicKey(_ data: Data) -> Bool {
        (try? P256.Signing.PublicKey(x963Representation: data)) != nil
    }

    /// Whether `envelope` carries a valid signature by `publicKey` (X9.63) over what it seals (`CompanionSeal.signedBytes`).
    /// The signature is ECDSA P-256 with SHA-256, as its 64 raw bytes.
    static func verify(envelope: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let bytes = CompanionSeal.signedBytes(envelope),
              let raw = CompanionSeal.signature(envelope),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: bytes)
    }

    /// The ops a Mac takes without a signature from a phone whose key it holds: `ping` alone, as it carries and returns
    /// nothing (the Mac's own relay check sends one with the pairing key).
    static func needsSignature(_ op: CompanionOp) -> Bool { op != .ping }
}
