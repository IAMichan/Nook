import SwiftUI
import AppKit

/// Een mail die Nook schreef: aan te passen in de chat, en weg met één klik op Versturen.
struct MailDraftView: View {
    let draft: MailDraft
    let onSend: (MailDraft) -> Void
    let onOpen: (MailDraft) -> Void

    @State private var to: String
    @State private var cc: String
    @State private var subject: String
    @State private var body_: String
    @State private var copied = false

    init(draft: MailDraft, onSend: @escaping (MailDraft) -> Void, onOpen: @escaping (MailDraft) -> Void) {
        self.draft = draft
        self.onSend = onSend
        self.onOpen = onOpen
        _to = State(initialValue: draft.to)
        _cc = State(initialValue: draft.cc)
        _subject = State(initialValue: draft.subject)
        _body_ = State(initialValue: draft.body)
    }

    private var edited: MailDraft {
        var copy = draft
        copy.to = to
        copy.cc = cc
        copy.subject = subject
        copy.body = body_
        return copy
    }

    private var locked: Bool { draft.state == .sent || draft.state == .sending }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NookTheme.iris)
                Text("Mailconcept")
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Spacer()
                statusLabel
            }
            .padding(.bottom, 8)

            field("Aan", text: $to, prompt: "naam@voorbeeld.nl")
            if !cc.isEmpty || !locked { field("Cc", text: $cc, prompt: "optioneel") }
            field("Onderwerp", text: $subject, prompt: "Onderwerp")

            TextEditor(text: $body_)
                .font(NookTheme.font(13.5))
                .foregroundStyle(NookTheme.paper)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(minHeight: 110, maxHeight: 220)
                .padding(.top, 8)
                .disabled(locked)

            HStack(spacing: 4) {
                if draft.state == .sent {
                    Label("Verstuurd", systemImage: "checkmark")
                        .font(NookTheme.font(13, .semibold))
                        .foregroundStyle(NookTheme.mint)
                } else {
                    SmallPrimaryButton(title: draft.state == .sending ? "Versturen…" : "Versturen", systemName: "paperplane.fill") {
                        onSend(edited)
                    }
                    .disabled(draft.state == .sending)
                    SmallGhostButton(title: "Open in Mail") { onOpen(edited) }
                }
                SmallGhostButton(title: copied ? "Gekopieerd" : "Kopieer") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(subject.isEmpty ? body_ : "\(subject)\n\n\(body_)", forType: .string)
                    copied = true
                }
                Spacer()
            }
            .padding(.top, 8)

            if case .failed(let message) = draft.state {
                Text(message)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NookTheme.line2, lineWidth: 1))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch draft.state {
        case .opened:
            Text("geopend in Mail").font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
        case .sent:
            Text("verstuurd").font(NookTheme.font(11)).foregroundStyle(NookTheme.mint)
        default:
            Text("jij verstuurt").font(NookTheme.font(11)).foregroundStyle(NookTheme.amber)
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 70, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(NookTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.paper)
                .disabled(locked)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(NookTheme.line2).frame(height: 1) }
    }
}

/// Kleine witte knop voor in de chat.
struct SmallPrimaryButton: View {
    let title: String
    var systemName: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemName { Image(systemName: systemName).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(NookTheme.font(13, .semibold))
            }
            .foregroundStyle(NookTheme.ink)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? Color.white : NookTheme.paper))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Kleine rustige knop voor in de chat.
struct SmallGhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
