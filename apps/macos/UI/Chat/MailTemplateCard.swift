import SwiftUI

/// What became of each mail an answer wrote (`MarkdownBlock.mail`), by the mail as written: the user's edits and whether
/// it went, so a card scrolled out of a lazy timeline and back does not offer Send again for a mail that was sent.
@MainActor
final class MailTemplateDrafts: ObservableObject {
    static let shared = MailTemplateDrafts()

    @Published private var drafts: [MailTemplate: MailDraft] = [:]

    func draft(for template: MailTemplate) -> MailDraft {
        drafts[template] ?? MailDraft(to: template.to, cc: template.cc, subject: template.subject, body: template.body,
                                      bcc: template.bcc, from: template.from)
    }

    func set(_ draft: MailDraft, for template: MailTemplate) {
        drafts[template] = draft
    }
}

/// A mail written in an answer (an agent's ```mail block, or a quoted draft), as the same mail card Nook Chat shows: To,
/// Cc, Bcc and Subject to fill in, the text to edit, and Send or Open in Mail. Nothing goes before the user's own click.
struct MailTemplateCard: View {
    let template: MailTemplate
    @ObservedObject private var drafts = MailTemplateDrafts.shared

    var body: some View {
        MailDraftView(
            draft: drafts.draft(for: template),
            onSend: { deliver($0, send: true) },
            onOpen: { deliver($0, send: false) },
            onDismiss: { update($0, .dismissed) },
            onReopen: { update($0, .draft) }
        )
        // A mail still being written starts over with each new piece of it; a finished one keeps the user's edits.
        .id(template)
    }

    private func update(_ draft: MailDraft, _ state: MailDraft.State) {
        var copy = draft
        copy.state = state
        drafts.set(copy, for: template)
    }

    private func deliver(_ draft: MailDraft, send: Bool) {
        update(draft, send ? .sending : .draft)
        Task { @MainActor in
            do {
                if send {
                    try await AppModel.shared.sendNewMail(draft)
                } else {
                    try await AppModel.shared.openNewMailInMail(draft)
                }
                update(draft, send ? .sent : .opened)
            } catch {
                update(draft, .failed(error.localizedDescription))
            }
        }
    }
}
