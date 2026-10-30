import Foundation
import CryptoKit

/// The writing samples and turned-down phrases autocomplete learns from are the user's own words: on disk they are encrypted
/// (AES-GCM, 256-bit) with a key that lives in the Keychain (Nook's vault), so a copy of the folder or a backup reads as noise.
/// The statistics are counts only and stay plain.
enum CompletionSealing {
    /// Starts every sealed file, so an older plain file is told apart (and sealed at the next save).
    static let magic = Data("NOOKSEAL1".utf8)
    /// The key's account in the Keychain vault (see `SecretStore`).
    static let keyAccount = "autocomplete.samplesKey"

    static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return magic + combined
    }

    /// The plain data, or nil when this key does not open it (another key, or damaged).
    static func open(_ data: Data, key: SymmetricKey) -> Data? {
        guard isSealed(data), let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// The key as text for the Keychain, and back.
    static func encode(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0).base64EncodedString() } }

    static func decode(_ text: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
}
