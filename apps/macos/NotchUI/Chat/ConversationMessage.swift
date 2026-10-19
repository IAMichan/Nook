import SwiftUI
import AppKit

/// One message in a conversation, shared by the Nook chat and the agent sessions: what you wrote in a soft box on the
/// right, the answer as formatted Markdown on the left (optionally under the name of whoever wrote it), with a copy
/// button that appears on hover.
struct ConversationMessage: View {
    let fromUser: Bool
    let text: String
    /// Who is answering (an agent's name); shown above the reply. Nil for the plain Nook chat.
    var author: String? = nil
    var accent: Color = NookTheme.iris
    var size: CGFloat = 13.5
    /// Answers a question at the end of the reply when one of its options is tapped; nil when it cannot be answered.
    var onChoose: ((String) -> Void)? = nil

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if fromUser { user } else { reply }
    }

    private var user: some View {
        // Pictures sent to an agent arrive as paths below the words: show the pictures above the bubble instead.
        let parts = ImageAttachment.splittingPaths(from: text)
        return VStack(alignment: .trailing, spacing: 6) {
            if !parts.images.isEmpty {
                MessagePictures(urls: parts.images)
            }
            if !parts.text.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 56)
                    Text(parts.text)
                        .font(NookTheme.font(size))
                        .foregroundStyle(NookTheme.paper)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NookTheme.smoke))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var reply: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let author, !author.isEmpty {
                HStack(spacing: 6) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(author)
                        .font(NookTheme.font(11.5, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: 0)
                    copyButton
                }
            }
            MarkdownView(text: text, size: size, onChoose: onChoose)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .buttonStyle(.plain)
        .opacity(hovering || copied ? 1 : 0)
        .accessibilityLabel(tr("button.copy"))
    }
}
