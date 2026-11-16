import Foundation

/// One environment variable of an account. A sensitive value (a token) is kept in the Keychain, not in Nook's settings.
struct AccountVariable: Codable, Hashable, Identifiable {
    var name: String
    /// Empty for a sensitive variable: its value is in the Keychain (`AgentProfileStore.value(of:for:)`).
    var value: String = ""
    var sensitive = false

    var id: String { name }

    /// Letters, digits and underscores, not starting with a digit (the shell's rule).
    static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }
}
