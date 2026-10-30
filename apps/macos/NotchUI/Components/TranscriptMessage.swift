import SwiftUI
import AppKit

// The messages of every conversation in Nook, one component for all of them: the Nook chat (`ChatMessageView`), a
// session Nook runs (`EventRow`), and an agent's own transcript (`TranscriptConversation`). What you wrote is a soft
// bubble on the right, the answer formatted text on the left without a bubble, and under both, on hover, the same
// footer with its time and copy button. Change a message here and every conversation follows.

/// The measurements every conversation shares, so the Nook chat and the agents read alike.
enum TranscriptStyle {
    /// The size of the words of a message, yours and the answer's.
    static let textSize: CGFloat = 14
    /// The room above each of your messages: every turn starts as a block of its own.
    static let turnGap = NookTheme.Spacing.xxl
    /// Your words stay narrower than the answer, so the thread reads as a conversation at a glance.
    static let bubbleInset: CGFloat = 64
    /// A message of yours longer than this folds to its first lines, with "Show full message" under it.
    static let foldCharacters = 600
    static let foldLines = 8
    /// How tall a folded message of yours is.
    static let foldedHeight: CGFloat = 176
    /// The column a work line's icon sits in, and how far what a line opens to (a thought, a command's output) is
    /// indented: to the words of the line above it.
    static let workIcon: CGFloat = 24
    static let workIndent: CGFloat = workIcon + NookTheme.Spacing.sm
}

/// What you wrote: pictures above a soft bubble on the right, a long message folded to its first lines, and on hover
/// its time and a copy button under it. Sent while the agent worked, a quiet "steered" mark sits above it.
struct TranscriptUserMessage<Attachments: View>: View {
    let text: String
    var date: Date? = nil
    /// Sent while the agent was working: it changed course mid-turn.
    var steered = false
    /// Pictures that came with the message as attachments rather than as paths in its text (the Nook chat's).
    @ViewBuilder var attachments: () -> Attachments
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        // Pictures sent to an agent arrive as paths below the words: show the pictures above the bubble instead.
        let parts = ImageAttachment.splittingPaths(from: text)
        let long = parts.text.count > TranscriptStyle.foldCharacters
            || parts.text.split(separator: "\n", omittingEmptySubsequences: false).count > TranscriptStyle.foldLines
        VStack(alignment: .trailing, spacing: NookTheme.Spacing.xs) {
            if steered {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                    Text(tr("agents.message.steered"))
                }
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
            }
            attachments()
            if !parts.images.isEmpty {
                MessagePictures(urls: parts.images)
            }
            if !parts.text.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: TranscriptStyle.bubbleInset)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        words(parts.text, folded: long && !expanded)
                        if long {
                            Button(expanded ? tr("agents.message.showLess") : tr("agents.message.showFull")) {
                                withAnimation(NookTheme.reveal) { expanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    // Room enough that a second line keeps clear of the round corners.
                    .padding(.horizontal, NookTheme.Spacing.xl)
                    .padding(.vertical, NookTheme.Spacing.lg)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.bubble, style: .continuous).fill(NookTheme.bubble))
                }
                TranscriptMessageFooter(text: text, date: date, visible: hovering, trailing: true) { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func words(_ string: String, folded: Bool) -> some View {
        let label = Text(string)
            .font(NookTheme.font(TranscriptStyle.textSize))
            .foregroundStyle(NookTheme.paper)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if folded {
            label
                .frame(maxHeight: TranscriptStyle.foldedHeight, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
        } else {
            label
        }
    }
}

extension TranscriptUserMessage where Attachments == EmptyView {
    init(text: String, date: Date? = nil, steered: Bool = false) {
        self.init(text: text, date: date, steered: steered) { EmptyView() }
    }
}

/// The answer: formatted text on the left without a bubble (under the name of whoever wrote it, when given), then what
/// came with it (`extras`: a chart, a mail, what a turn changed), and on hover a footer with copy, the answer's own
/// `actions` (try again) and its time.
struct TranscriptReply<Extras: View, Actions: View>: View {
    let text: String
    var date: Date? = nil
    /// Who is answering (an agent's name), above the answer; nil where it is clear (the Nook chat, one agent's session).
    var author: String? = nil
    var accent: Color = NookTheme.iris
    /// The footer under the answer; off for the in-between answers of a turn, so only its final answer has one.
    var footer = true
    /// Answers a question at the end of the reply when one of its options is tapped; nil when it cannot be answered.
    var onChoose: ((String) -> Void)? = nil
    @ViewBuilder var extras: () -> Extras
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                if !text.isEmpty {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        if let author, !author.isEmpty {
                            HStack(spacing: NookTheme.Spacing.sm) {
                                Circle().fill(accent).frame(width: 6, height: 6)
                                Text(author)
                                    .font(NookTheme.TextStyle.label)
                                    .foregroundStyle(NookTheme.textSecondary)
                            }
                        }
                        MarkdownView(text: text, size: TranscriptStyle.textSize, onChoose: onChoose)
                    }
                }
                extras()
            }
            if footer && !text.isEmpty {
                TranscriptMessageFooter(text: text, date: date, visible: hovering, trailing: false, actions: actions)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension TranscriptReply where Extras == EmptyView, Actions == EmptyView {
    init(text: String, date: Date? = nil, author: String? = nil, accent: Color = NookTheme.iris, footer: Bool = true,
         onChoose: ((String) -> Void)? = nil) {
        self.init(text: text, date: date, author: author, accent: accent, footer: footer, onChoose: onChoose,
                  extras: { EmptyView() }, actions: { EmptyView() })
    }
}

extension TranscriptReply where Actions == EmptyView {
    init(text: String, date: Date? = nil, author: String? = nil, accent: Color = NookTheme.iris, footer: Bool = true,
         onChoose: ((String) -> Void)? = nil, @ViewBuilder extras: @escaping () -> Extras) {
        self.init(text: text, date: date, author: author, accent: accent, footer: footer, onChoose: onChoose,
                  extras: extras, actions: { EmptyView() })
    }
}

/// Under a message, on hover: copy, the message's own actions, and when it was written. It keeps its place while
/// hidden, so nothing jumps when the pointer moves over the thread.
struct TranscriptMessageFooter<Actions: View>: View {
    let text: String
    let date: Date?
    let visible: Bool
    /// Under your bubble on the right (time first), or under an answer on the left (copy first).
    let trailing: Bool
    @ViewBuilder var actions: () -> Actions
    @State private var copied = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if trailing, let date { TranscriptTime(date: date).padding(.trailing, NookTheme.Spacing.xs) }
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", copied ? tr("button.copied") : tr("button.copy"), height: 22) {
                Pasteboard.copy(text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            actions()
            if !trailing, let date { TranscriptTime(date: date).padding(.leading, NookTheme.Spacing.xs) }
        }
        // The icons line up with the text above them, not their own hover fill.
        .padding(trailing ? .trailing : .leading, -NookTheme.Spacing.xs)
        .opacity(visible || copied ? 1 : 0)
        .animation(NookTheme.hover, value: visible)
    }
}

/// "14:03" today, "12 Oct 14:03" before; the full date on hover.
struct TranscriptTime: View {
    let date: Date

    var body: some View {
        let text = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        Text(text)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(date.formatted(date: .complete, time: .shortened))
    }
}
