import Foundation
import CryptoKit

/// The signature check of a release update (`UpdateSignature`) with CryptoKit: Ed25519 over the downloaded .zip, against
/// the public key in Info.plist. scripts/sign-update.swift signs with the matching private key.
struct Ed25519Verifier: UpdateSignatureVerifier {
    func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
