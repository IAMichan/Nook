import AppKit
import Foundation

/// Sends or opens an email via the Mail app. Only after the user clicks "Send" or "Open in Mail".
@MainActor
enum MailSender {
    static let mailBundleID = "com.apple.mail"
    /// Thrown by the script itself when Mail has no account to send from.
    static let noAccountError = 9001
    /// Mail has to start, load its accounts and hand the message to the server: the 4 seconds a lookup gets is far too
    /// little for that, and a cold Mail then fails with -1712 although nothing is wrong.
    static let sendTimeout: TimeInterval = 45

    /// Parses email addresses from "lisa@x.nl, Bram <bram@y.nl>; …".
    nonisolated static func addresses(_ text: String) -> [String] {
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

    nonisolated static func isValidAddress(_ address: String) -> Bool {
        address.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    /// `send: true` sends immediately; otherwise opens the draft in Mail so you can finish it there.
    static func deliver(_ draft: MailDraft, send: Bool) async throws {
        let to = addresses(draft.to)
        let cc = addresses(draft.cc)
        let from = addresses(draft.from).first ?? ""
        if send {
            guard !to.isEmpty else { throw NookError(tr("mail.send.noRecipient")) }
            if let wrong = (to + cc).first(where: { !isValidAddress($0) }) {
                throw NookError(tr("mail.send.invalidAddress", wrong))
            }
        }
        await launchMail()
        let result = await ScriptText.run(script(draft, to: to, cc: cc, from: from, send: send), timeout: sendTimeout)
        if let error = result.errorNumber {
            throw NookError(message(for: error, send: send))
        }
    }

    /// The AppleScript that makes the message. The sender is only set when Mail has an account with that address:
    /// otherwise Mail would send from an address it cannot send from.
    static func script(_ draft: MailDraft, to: [String], cc: [String], from: String, send: Bool) -> String {
        var recipients = ""
        for address in to {
            recipients += "\n        make new to recipient at end of to recipients with properties {address:\(ScriptText.quote(address))}"
        }
        for address in cc {
            recipients += "\n        make new cc recipient at end of cc recipients with properties {address:\(ScriptText.quote(address))}"
        }
        var sender = ""
        if !from.isEmpty {
            sender = """

                set wanted to \(ScriptText.quote(from.lowercased()))
                repeat with anAccount in accounts
                    repeat with anAddress in (email addresses of anAccount)
                        if (anAddress as text) is wanted then set sender of m to (anAddress as text)
                    end repeat
                end repeat
            """
        }
        let guardAccount = send ? "\n    if (count of accounts) is 0 then error \"no account\" number \(noAccountError)" : ""
        return """
        tell application "Mail"\(guardAccount)
            set m to make new outgoing message with properties {subject:\(ScriptText.quote(draft.subject)), content:\(ScriptText.quote(draft.body)), visible:\(send ? "false" : "true")}
            tell m\(recipients)
            end tell\(sender)
            \(send ? "send m" : "activate")
        end tell
        """
    }

    /// What went wrong, in the user's language.
    static func message(for error: Int, send: Bool) -> String {
        switch error {
        case -1743: return tr("mail.send.permission")
        case noAccountError: return tr("mail.send.noAccount")
        // After a timeout Mail may still send the message: say so, so it is not sent twice.
        case -1712: return send ? tr("mail.send.timeout") : tr("mail.open.timeout")
        case -600, -609: return tr("mail.send.notRunning")
        default: return send ? tr("mail.send.failed", error) : tr("mail.open.failed", error)
        }
    }

    /// Starts Mail when it is not running and waits until it can take AppleEvents, so the script does not spend its
    /// time on Mail's launch.
    private static func launchMail() async {
        guard !ScriptText.isRunning(mailBundleID),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<40 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: mailBundleID).contains(where: \.isFinishedLaunching) { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
