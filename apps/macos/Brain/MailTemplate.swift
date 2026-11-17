import Foundation

/// A mail an answer wrote for the user to send: shown as a mail card (From, To, Cc, Bcc, Subject and the text) instead of
/// a block of text, so the user can fill in what is missing and send it, or open it in Mail.
///
/// An agent writes it as a ```mail block: header lines (`To:`, `Cc:`, `Bcc:`, `Subject:`, `From:`, also in the five app
/// languages), a blank line, then the text. A quoted draft (`> Hi Jan, … > Regards,`) becomes one too, with the
/// headers it has, so a mail written as a plain quote still gets the card.
struct MailTemplate: Equatable, Hashable {
    var from = ""
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""

    /// The fence languages that hold a mail.
    static let languages: Set<String> = ["mail", "email", "e-mail", "eml"]

    private enum Header { case from, to, cc, bcc, subject }

    /// Header names, lowercased, in English, Dutch, German, French and Spanish.
    private static let headers: [String: Header] = [
        "from": .from, "van": .from, "von": .from, "de": .from, "sender": .from, "afzender": .from,
        "to": .to, "aan": .to, "an": .to, "à": .to, "a": .to, "para": .to, "recipient": .to, "recipients": .to,
        "ontvanger": .to, "ontvangers": .to, "destinataire": .to, "destinataires": .to, "empfänger": .to,
        "cc": .cc, "kopie": .cc, "copie": .cc, "copia": .cc,
        "bcc": .bcc, "cci": .bcc, "cco": .bcc, "bkopie": .bcc,
        "subject": .subject, "onderwerp": .subject, "betreff": .subject, "objet": .subject, "asunto": .subject
    ]

    /// The header a line opens (`**Subject:** Hello` too), and its value; nil when the line is text.
    private static func header(_ line: String) -> (Header, String)? {
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let colon = plain.firstIndex(of: ":") else { return nil }
        let name = plain[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard name.count <= 14, let kind = headers[name] else { return nil }
        return (kind, plain[plain.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// Reads header lines from the top of `text`, the rest is the body. `needsHeaders`: nil when no header line came first.
    private static func read(_ text: String, needsHeaders: Bool) -> MailTemplate? {
        var lines = text.components(separatedBy: "\n")
        var mail = MailTemplate()
        var found = 0
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeFirst()
                // The blank line after the headers starts the text; one before any header is skipped.
                if found > 0 { break }
                continue
            }
            guard let (kind, value) = header(trimmed) else { break }
            switch kind {
            case .from: mail.from = value
            case .to: mail.to = value
            case .cc: mail.cc = value
            case .bcc: mail.bcc = value
            case .subject: mail.subject = value
            }
            found += 1
            lines.removeFirst()
        }
        if needsHeaders, found == 0 { return nil }
        mail.body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return mail
    }

    /// The mail in a ```mail block. Without any header line, all of it is the text.
    static func fenced(_ body: String) -> MailTemplate {
        read(body, needsHeaders: false) ?? MailTemplate(body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Words a mail opens with, lowercased, in the five app languages.
    private static let greetings = [
        "hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening",
        "hoi", "hallo", "beste", "lieve", "geachte", "goedemorgen", "goedemiddag", "goedenavond", "dag",
        "liebe", "lieber", "sehr geehrte", "sehr geehrter", "guten tag", "moin",
        "bonjour", "bonsoir", "cher", "chère", "salut", "madame", "monsieur",
        "hola", "estimado", "estimada", "buenos días", "buenas tardes", "querido", "querida"
    ]

    /// Lines a mail closes with, lowercased, without their comma.
    private static let signOffs = [
        "regards", "kind regards", "best regards", "best", "cheers", "thanks", "thank you", "sincerely", "yours sincerely",
        "all the best", "warm regards",
        "groet", "groeten", "met vriendelijke groet", "met vriendelijke groeten", "vriendelijke groet", "hartelijke groet",
        "hartelijke groeten", "groetjes", "liefs", "dank", "bedankt", "alvast bedankt", "mvg", "gr",
        "grüße", "gruß", "viele grüße", "beste grüße", "mit freundlichen grüßen", "lg", "vg",
        "cordialement", "bien à vous", "bien cordialement", "salutations", "merci", "à bientôt", "bises",
        "saludos", "un saludo", "atentamente", "un abrazo", "gracias", "cordiales saludos"
    ]

    private static func opensWithGreeting(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        guard lower.hasSuffix(","), lower.count <= 60 else { return false }
        return greetings.contains { lower == $0 + "," || lower.hasPrefix($0 + " ") }
    }

    private static func isSignOff(_ line: String) -> Bool {
        var lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        while let last = lower.last, ",.!".contains(last) { lower.removeLast() }
        return signOffs.contains(lower)
    }

    /// A quote that is a mail: it opens with mail headers, or with a greeting and closes with a sign-off near its end.
    static func quoted(_ text: String) -> MailTemplate? {
        if let mail = read(text, needsHeaders: true), !mail.to.isEmpty || !mail.subject.isEmpty, !mail.body.isEmpty {
            return mail
        }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 3, let first = lines.first, opensWithGreeting(first),
              lines.suffix(3).contains(where: isSignOff) else { return nil }
        return MailTemplate(body: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
