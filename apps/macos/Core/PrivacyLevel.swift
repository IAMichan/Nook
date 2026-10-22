import Foundation

/// How tightly Nook guards what an external brain gets to see (Settings › Privacy). A brain on this Mac sees everything:
/// nothing leaves the Mac. Whatever the level, password managers and password fields are never read, keys stay in the
/// Keychain and nothing runs without a click.
enum PrivacyLevel: String, CaseIterable, Identifiable, Codable {
    /// Context goes as it is: the best answers, nothing taken out.
    case open
    /// Secrets are taken out first: passwords, API keys and tokens, private keys, card numbers, IBANs and BSNs.
    case balanced
    /// Secrets and contact details (e-mail addresses, phone numbers) are taken out, and the screen and the clipboard
    /// stay on this Mac.
    case strict

    var id: String { rawValue }

    var titleKey: String { "settings.privacy.level.\(rawValue)" }
    var detailKey: String { "settings.privacy.level.\(rawValue).detail" }

    /// Sources an external brain never gets at this level, on top of the ones the user keeps on this Mac by hand.
    var localOnlySources: Set<String> {
        self == .strict ? [SourceCatalog.screen, "clipboard"] : []
    }
}

/// Takes out what the privacy level keeps on this Mac from text Nook gathered (context, screen text, what tools read)
/// before it goes to an external brain. What the user types is never changed: they chose to send that.
enum PrivacyFilter {
    static let email = "[email]"
    static let phone = "[phone]"

    private static let emailPattern = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}\b"#)
    /// International numbers (+31 6 12345678, 0031 20 123 4567) and Dutch-style numbers with a leading zero (06-12345678,
    /// 020 123 4567).
    private static let phonePattern = try! NSRegularExpression(
        pattern: #"(?<![\w+])(?:\+|00)[1-9]\d{0,2}[ \-]?(?:\(0\)[ \-]?)?\d(?:[ \-]?\d){6,11}\b|(?<![\w+\-])0\d(?:[ \-]?\d){8}\b"#)
    /// Long random tokens without a known prefix: upper and lower case letters and digits mixed. Identifiers a model
    /// still has to act on (UUIDs, commit hashes) use one case and stay.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[a-z])(?=[A-Za-z0-9_\-]*[A-Z])[A-Za-z0-9_\-]{32,}\b"#)

    static func apply(_ text: String, level: PrivacyLevel) -> String {
        switch level {
        case .open:
            return text
        case .balanced:
            return CompletionPrivacy.sanitize(text, generic: false)
        case .strict:
            var result = CompletionPrivacy.sanitize(text, generic: false)
            result = replace(tokenPattern, in: result, with: CompletionPrivacy.placeholder)
            result = replace(emailPattern, in: result, with: email)
            return replace(phonePattern, in: result, with: phone)
        }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with placeholder: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                         withTemplate: NSRegularExpression.escapedTemplate(for: placeholder))
    }
}
