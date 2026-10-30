import SwiftUI

/// Writing a mail in the Chats tab, in the pane where a conversation shows: a new mail, an answer to everyone, or a mail
/// forwarded. From (each address of every account in Mail), To, Cc and the subject on lines of their own, the text below
/// over the rest of the pane, and Send (⌘↩), Open in Mail to finish it there, and Discard (Escape). Nothing goes before
/// your own click; Mail sends it from the account you chose. Never build a mail form by hand.
struct MailComposeView: View {
    @Binding var draft: MailDraft
    /// Every address you can send from, as "Account — address"; empty leaves it to Mail's default account.
    let senders: [(account: String, address: String)]
    let onSend: () -> Void
    let onOpenInMail: () -> Void
    let onClose: () -> Void

    @FocusState private var focus: Field?

    private enum Field: Hashable { case to, cc, subject, body }

    private var locked: Bool { draft.state == .sending || draft.state == .sent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, NookTheme.Spacing.md)
            NookDivider()
            VStack(alignment: .leading, spacing: 0) {
                if !senders.isEmpty { fromLine }
                line(tr("chat.mail.to"), text: $draft.to, prompt: tr("chat.mail.emailPrompt"), field: .to)
                line(tr("chat.mail.cc"), text: $draft.cc, prompt: tr("chat.mail.optional"), field: .cc)
                line(tr("chat.mail.subject"), text: $draft.subject, prompt: tr("chat.mail.subject"), field: .subject)
                editor
                footer
            }
            .chatColumn()
        }
        .onAppear { focus = draft.to.isEmpty ? .to : .body }
        .onEscapeKey(enabled: !locked) { onClose() }
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: "square.and.pencil")
                .font(NookTheme.font(13, .medium))
                .foregroundStyle(NookTheme.textSecondary)
            Text(draft.subject.trimmingCharacters(in: .whitespaces).isEmpty ? tr("chats.mail.new") : draft.subject)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
            Spacer()
            ToolbarIconButton("xmark", tr("chats.mail.discard"), enabled: !locked) { onClose() }
        }
        .padding(.top, NookTheme.Spacing.xs)
    }

    /// The address it goes from: a menu of every address of every account.
    private var fromLine: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            label(tr("chat.mail.from"))
            Menu {
                ForEach(Array(senders.enumerated()), id: \.offset) { _, sender in
                    Button("\(sender.account) — \(sender.address)") { draft.from = sender.address }
                }
            } label: {
                Text(fromTitle)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(locked)
            Spacer()
        }
        .padding(.vertical, NookTheme.Spacing.md)
        .overlay(alignment: .bottom) { NookDivider() }
    }

    private var fromTitle: String {
        let chosen = senders.first { $0.address.lowercased() == draft.from.lowercased() } ?? senders.first
        guard let chosen else { return draft.from }
        return "\(chosen.account) — \(chosen.address)"
    }

    private func line(_ title: String, text: Binding<String>, prompt: String, field: Field) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            label(title)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .focused($focus, equals: field)
                .disabled(locked)
        }
        .padding(.vertical, NookTheme.Spacing.md)
        .overlay(alignment: .bottom) { NookDivider() }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .frame(width: 64, alignment: .leading)
    }

    /// The text over the rest of the pane, with a prompt while it is empty.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if draft.body.isEmpty {
                Text(tr("chats.mail.bodyPrompt"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.top, NookTheme.Spacing.xxs)
                    .padding(.leading, NookTheme.Spacing.xs)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft.body)
                .font(NookTheme.TextStyle.body)
                .lineSpacing(NookTheme.Spacing.xxs)
                .foregroundStyle(NookTheme.paper)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .body)
                .disabled(locked)
        }
        .padding(.top, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if case .failed(let message) = draft.state {
                Text(message)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if draft.state == .sent {
                    Label(tr("chat.mail.sent"), systemImage: "checkmark")
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.mint)
                } else {
                    SmallPrimaryButton(title: draft.state == .sending ? tr("button.sending") : tr("button.send"),
                                       systemName: "paperplane.fill", action: onSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(locked || draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
                    SmallGhostButton(title: tr("button.openInMail"), action: onOpenInMail)
                        .disabled(locked)
                }
                Spacer()
                Text(tr("chats.mail.sendHint"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(.vertical, NookTheme.Spacing.md)
        .overlay(alignment: .top) { NookDivider() }
    }
}
