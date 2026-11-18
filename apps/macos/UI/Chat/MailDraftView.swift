import SwiftUI
import AppKit

/// An email drafted by Nook: editable in chat, and sent with a single click.
struct MailDraftView: View {
    let draft: MailDraft
    let onSend: (MailDraft) -> Void
    let onOpen: (MailDraft) -> Void
    let onDismiss: (MailDraft) -> Void
    let onReopen: (MailDraft) -> Void

    @State private var from: String
    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var subject: String
    @State private var body_: String
    /// `@` in the body: people from your chats by name.
    @StateObject private var mentionModel = ComposerModel()

    init(draft: MailDraft, onSend: @escaping (MailDraft) -> Void, onOpen: @escaping (MailDraft) -> Void,
         onDismiss: @escaping (MailDraft) -> Void, onReopen: @escaping (MailDraft) -> Void) {
        self.draft = draft
        self.onSend = onSend
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        self.onReopen = onReopen
        _from = State(initialValue: draft.from)
        _to = State(initialValue: draft.to)
        _cc = State(initialValue: draft.cc)
        _bcc = State(initialValue: draft.bcc)
        _subject = State(initialValue: draft.subject)
        _body_ = State(initialValue: draft.body)
    }

    private var edited: MailDraft {
        var copy = draft
        copy.from = from
        copy.to = to
        copy.cc = cc
        copy.bcc = bcc
        copy.subject = subject
        copy.body = body_
        return copy
    }

    private var locked: Bool { draft.state == .sent || draft.state == .sending }

    /// Sent or on its way: nothing left to close.
    private var closable: Bool { !locked }

    var body: some View {
        if draft.state == .dismissed {
            dismissedRow
        } else {
            card
        }
    }

    /// A closed draft folds to one line, so the conversation stays readable and the draft can still come back.
    private var dismissedRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "envelope")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)
            Text(subject.isEmpty ? tr("chat.mail.concept") : subject)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(tr("chat.mail.dismissed"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
            Spacer()
            SmallGhostButton(title: tr("chat.mail.reopen")) { onReopen(edited) }
        }
        .padding(.horizontal, NookTheme.Spacing.xl)
        .padding(.vertical, NookTheme.Spacing.md)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.sheet)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: "envelope")
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(tr("chat.mail.concept"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Spacer()
                statusLabel
                if closable {
                    ToolbarIconButton("xmark", tr("chat.mail.dismiss"), height: 20, width: 20) { onDismiss(edited) }
                }
            }
            .padding(.bottom, NookTheme.Spacing.md)

            // The account to send from, only when the user named one; otherwise Mail's default account sends it.
            if !draft.from.isEmpty { field(tr("chat.mail.from"), text: $from, prompt: tr("chat.mail.emailPrompt")) }
            field(tr("chat.mail.to"), text: $to, prompt: tr("chat.mail.emailPrompt"))
            if !cc.isEmpty || !locked { field(tr("chat.mail.cc"), text: $cc, prompt: tr("chat.mail.optional")) }
            if !bcc.isEmpty || !locked { field(tr("chat.mail.bcc"), text: $bcc, prompt: tr("chat.mail.optional")) }
            field(tr("chat.mail.subject"), text: $subject, prompt: tr("chat.mail.subject"))
            if let invite = draft.invite { inviteRow(invite) }

            MentionSuggestions(model: mentionModel, text: $body_, config: .mentions())
                .padding(.top, mentionModel.isOpen ? NookTheme.Spacing.md : 0)
            TextEditor(text: $body_)
                .mentions(mentionModel, text: $body_, config: .mentions())
                .font(NookTheme.TextStyle.body)
                .lineSpacing(3)
                .foregroundStyle(NookTheme.paper)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(minHeight: 110, maxHeight: 220)
                .padding(.top, NookTheme.Spacing.md)
                .disabled(locked)

            HStack(spacing: NookTheme.Spacing.xs) {
                // A sent mail says so once, in its header; here only Copy stays.
                if draft.state != .sent {
                    SmallPrimaryButton(title: draft.state == .sending ? tr("button.sending") : tr("button.send"), systemName: "paperplane.fill") {
                        onSend(edited)
                    }
                    .disabled(draft.state == .sending)
                    SmallGhostButton(title: tr("button.openInMail")) { onOpen(edited) }
                }
                CopyGhostButton { subject.isEmpty ? body_ : "\(subject)\n\n\(body_)" }
                Spacer()
            }
            .padding(.top, NookTheme.Spacing.md)

            if case .failed(let message) = draft.state {
                InlineErrorText(message)
                    .padding(.top, NookTheme.Spacing.sm)
            }
        }
        .padding(NookTheme.Spacing.xl)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.sheet)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch draft.state {
        case .opened:
            Text(tr("chat.mail.openedInMail")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
        case .sent:
            Label(tr("chat.mail.sent"), icon: "checkmark")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.mint)
        default:
            Text(tr("chat.mail.youSend")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
        }
    }

    /// The calendar invitation that goes with the mail, so the user sees what the recipients will be asked to accept.
    private func inviteRow(_ invite: CalendarInvite.Event) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "calendar.badge.plus")
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.iris)
            Text(tr("chat.mail.invite", "\(invite.title) · \(NookDates.dayAndClock(invite.start))–\(NookDates.clock(invite.end))"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.vertical, NookTheme.Spacing.md)
        .overlay(alignment: .bottom) { NookDivider() }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Text(label)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 64, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .disabled(locked)
        }
        .padding(.vertical, NookTheme.Spacing.md)
        .overlay(alignment: .bottom) { NookDivider() }
    }
}
