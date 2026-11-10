import Foundation
import CryptoKit

/// Sealing between a guest's browser and the Mac (guest links, docs/WORKSPACE-AGENTS.md): AES-256-GCM, because a browser's
/// WebCrypto has it and has no ChaCha20-Poly1305. The key is 32 random bytes that only live in the link's fragment, which a
/// browser never sends, so the relay passes bytes it can neither read nor forge. A sealed message is
/// `nonce (12 bytes) + ciphertext + tag (16 bytes)`; the page (apps/relay/worker/guest.js) opens and seals the same.
///
/// The room is derived from the key with `GuestLinkRoom` (portable, `PureHMAC`), so it is in `CompanionRelay`'s format and
/// tells nothing about the key.
enum GuestLinkSeal {
    static let keyBytes = 32

    static func newKey() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }

    static func seal(_ plain: Data, key: Data) -> Data? {
        seal(plain, key: key, nonce: Data((0..<12).map { _ in UInt8.random(in: 0...255) }))
    }

    /// With a given nonce: only for the shared test vector. A nonce must never be used twice with the same key.
    static func seal(_ plain: Data, key: Data, nonce: Data) -> Data? {
        guard key.count == keyBytes, let nonce = try? AES.GCM.Nonce(data: nonce),
              let box = try? AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce) else { return nil }
        return Data(nonce) + box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: Data) -> Data? {
        guard key.count == keyBytes, sealed.count >= 28, let nonce = try? AES.GCM.Nonce(data: sealed.prefix(12)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed.dropFirst(12).dropLast(16), tag: sealed.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }
}
