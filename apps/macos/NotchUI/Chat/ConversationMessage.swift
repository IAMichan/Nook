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
        return VStack(alignment: .trailing, spacing: NookTheme.Spacing.sm) {
            if !parts.images.isEmpty {
                MessagePictures(urls: parts.images)
            }
            if !parts.text.isEmpty {
                HStack(spacing: 0) {
                    // Your words stay narrower than the answer, so the thread reads as a conversation at a glance.
                    Spacer(minLength: 64)
                    Text(parts.text)
                        .font(NookTheme.font(size))
                        .foregroundStyle(NookTheme.paper)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(NookTheme.Spacing.lg)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.bubble, style: .continuous).fill(NookTheme.bubble))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var reply: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let author, !author.isEmpty {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Circle().fill(accent).frame(width: 6, height: 6)
                    Text(author)
                        .font(NookTheme.TextStyle.label)
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

    private var copyButton: some View {
        ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", copied ? tr("button.copied") : tr("button.copy"), height: 20) {
            Pasteboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .opacity(hovering || copied ? 1 : 0)
    }
}
