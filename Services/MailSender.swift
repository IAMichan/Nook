import Foundation

/// Verstuurt of opent een mail via de app Mail. Alleen na een klik van de gebruiker op "Versturen" of "Open in Mail".
@MainActor
enum MailSender {
    /// Adressen uit "lisa@x.nl, Bram <bram@y.nl>; …".
    static func addresses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if let open = trimmed.firstIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                    return String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty }
    }

    static func isValidAddress(_ address: String) -> Bool {
        address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    /// `send: true` verstuurt meteen; anders opent het concept in Mail zodat je het daar afmaakt.
    static func deliver(_ draft: MailDraft, send: Bool) async throws {
        let to = addresses(draft.to)
        let cc = addresses(draft.cc)
        if send {
            guard !to.isEmpty else { throw NookError("Vul eerst een ontvanger in.") }
            if let wrong = (to + cc).first(where: { !isValidAddress($0) }) {
                throw NookError("\"\(wrong)\" is geen geldig mailadres.")
            }
        }
        var recipients = ""
        for address in to {
            recipients += "\n        make new to recipient at end of to recipients with properties {address:\(ScriptText.quote(address))}"
        }
        for address in cc {
            recipients += "\n        make new cc recipient at end of cc recipients with properties {address:\(ScriptText.quote(address))}"
        }
        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:\(ScriptText.quote(draft.subject)), content:\(ScriptText.quote(draft.body)), visible:\(send ? "false" : "true")}
            tell m\(recipients)
            end tell
            \(send ? "send m" : "activate")
        end tell
        """
        let result = await ScriptText.run(script)
        if let error = result.errorNumber {
            if error == -1743 {
                throw NookError("Geef Nook toestemming voor Mail bij Systeeminstellingen › Privacy en beveiliging › Automatisering.")
            }
            throw NookError(send ? "Versturen via Mail lukte niet (fout \(error)). Is er een account ingesteld in Mail?" : "Mail openen lukte niet (fout \(error)).")
        }
    }
}
