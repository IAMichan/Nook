import SwiftUI
import AppKit

// The messages of every conversation in Nook, one component for all of them: the Nook chat (`ChatMessageView`), a
// session Nook runs (`EventRow`), and an agent's own transcript (`TranscriptConversation`). What you wrote is a soft
// bubble on the right, the answer formatted text on the left without a bubble, and under both, on hover, the same
// footer with its time and copy button. Change a message here and every conversation follows.

// `TranscriptStyle`, `TranscriptUserBubble`, `transcriptFolded` and `TranscriptTime` are shared with the iPhone
// (NotchUI/Shared/TranscriptParts.swift).

/// What you wrote: pictures and attached files above a soft bubble on the right, a long message folded to its first lines, and on hover
/// its time and a copy button under it (and "Edit from here" where the session can go back to before it). Sent while
/// the agent worked, a quiet "steered" mark sits above it.
struct TranscriptUserMessage<Attachments: View>: View {
    let text: String
    var date: Date? = nil
    /// Sent while the agent was working: it changed course mid-turn.
    var steered = false
    /// It waited in the queue first and was then taken into the running turn.
    var promoted = false
    /// Whether the agent read the steer yet (`SteerReceipts`): nil once it did, or when the agent does not say.
    var steerStatus: RunEvent.SteerStatus? = nil
    /// "Edit from here": goes back to before this message and puts it in the composer again; nil where it cannot.
    var onEdit: (() -> Void)? = nil
    /// Pictures that came with the message as attachments rather than as paths in its text (the Nook chat's).
    @ViewBuilder var attachments: () -> Attachments
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.fileLinkBase) private var fileLinkBase

    var body: some View {
        // Pictures, files and folders sent to an agent arrive as paths below the words (an agent's own transcript still
        // holds the context envelope): show them above the bubble instead.
        let parts = ImageAttachment.splittingAttachments(from: ContextRefs.timeline(text, folder: fileLinkBase))
        let long = TranscriptStyle.isLong(parts.text)
        VStack(alignment: .trailing, spacing: NookTheme.Spacing.xs) {
            if steered || promoted {
                // "↪ Steer" marks a message that went into the turn while it ran.
                // Not read yet: "Steer · waiting to be read" until the agent takes it in between steps.
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(icon: "arrow.uturn.right")
                    Text(steerLabel)
                }
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .help(steerHelp)
                .accessibilityElement(children: .combine)
            }
            attachments()
            if !parts.images.isEmpty {
                MessagePictures(urls: parts.images)
            }
            if !parts.files.isEmpty {
                MessageFiles(urls: parts.files)
            }
            if !parts.text.isEmpty {
                TranscriptUserBubble {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        words(parts.text, folded: long && !expanded)
                        if long {
                            Button(expanded ? tr("agents.message.showLess") : tr("agents.message.showFull")) {
                                withAnimation(NookTheme.reveal) { expanded.toggle() }
                            }
                            .buttonStyle(.nookPlain)
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                }
                TranscriptMessageFooter(text: text, date: date, visible: hovering, trailing: true) {
                    // A nook://prompt link that opens this prompt as a draft in a new session, to share or keep.
                    if let link = PromptLink.build(text: parts.text, project: fileLinkBase.map { ($0 as NSString).lastPathComponent }) {
                        CopyIconButton(tr("agents.message.copyPromptLink"), symbol: "link", copiedLabel: tr("agents.message.promptLinkCopied"),
                                       height: 22, width: 22) { link.absoluteString }
                    }
                    if let onEdit {
                        ToolbarIconButton("pencil", tr("agents.message.editFromHere"), height: 22, width: 22, onEdit)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var steerLabel: String {
        switch steerStatus {
        case .pending: return tr("agents.message.steerWaiting")
        case .cancelled: return tr("agents.message.steerDropped")
        case nil: return tr("agents.message.steer")
        }
    }

    private var steerHelp: String {
        switch steerStatus {
        case .pending: return tr("agents.message.steerWaitingHelp")
        case .cancelled: return tr("agents.message.steerDroppedHelp")
        case nil: return promoted ? tr("agents.message.steerPromotedHelp") : tr("agents.message.steerHelp")
        }
    }

    /// Your words in Markdown, as the agent reads them: a quote, list or code block as such, `code` and **bold** inline.
    /// Only a message with blocks takes the whole width of the bubble; one of plain lines keeps hugging its words. A
    /// message that starts with a quote (a reply to an answer, a quoted passage) shows that quote as a card above the
    /// words about it.
    @ViewBuilder
    private func words(_ string: String, folded: Bool) -> some View {
        if let lead = AnswerReply.leadingQuote(string) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                TranscriptQuoteCard(text: lead.quote)
                if !lead.rest.isEmpty { plainWords(lead.rest) }
            }
            .transcriptFolded(folded)
        } else {
            plainWords(string)
                .transcriptFolded(folded)
        }
    }

    @ViewBuilder
    private func plainWords(_ string: String) -> some View {
        if TranscriptStyle.hasMarkdownBlocks(string) {
            MarkdownView(text: string, size: TranscriptStyle.textSize)
                .equatable()
        } else {
            Text(MarkdownBlock.inline(string, size: TranscriptStyle.textSize, files: fileLinkBase != nil))
                .font(NookTheme.font(TranscriptStyle.textSize))
                .foregroundStyle(NookTheme.paper)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// The quote a message of yours starts with (`AnswerReply.leadingQuote`), as an inset card at the top of your bubble:
/// a bar and the quoted words, quieter than yours, at most a few lines; all of it on hover.
struct TranscriptQuoteCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Text(MarkdownBlock.inline(text, size: 12, files: false))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineSpacing(2)
                .lineLimit(4)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, NookTheme.Spacing.sm)
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.md)
        .overlay(alignment: .leading) {
            Capsule().fill(NookTheme.textTertiary).frame(width: 3)
                .padding(.vertical, NookTheme.Spacing.sm).padding(.leading, NookTheme.Spacing.xs)
        }
        .roundedBackground(NookTheme.wash.opacity(0.05), radius: NookTheme.Radius.control)
        .help(text)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("agents.message.quoteLabel", text))
    }
}

extension TranscriptUserMessage where Attachments == EmptyView {
    init(text: String, date: Date? = nil, steered: Bool = false, promoted: Bool = false,
         steerStatus: RunEvent.SteerStatus? = nil, onEdit: (() -> Void)? = nil) {
        self.init(text: text, date: date, steered: steered, promoted: promoted, steerStatus: steerStatus, onEdit: onEdit) { EmptyView() }
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
    @State private var files: [String] = []
    @Environment(\.fileLinkBase) private var fileLinkBase
    @Environment(\.sessionSide) private var side
    @Environment(\.replyToAnswer) private var replyToAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
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
                            .equatable()
                    }
                }
                // In an agent's conversation: the files the turn's answer names, a click from the side panel.
                if !files.isEmpty { AnswerFilesRow(paths: files) }
                extras()
            }
            if footer && !text.isEmpty {
                TranscriptMessageFooter(text: text, date: date, visible: hovering, trailing: false) {
                    // "Reply": this answer, or the part of it you selected, as a quote at the top of the composer.
                    if let replyToAnswer {
                        ToolbarIconButton("arrowshape.turn.up.left", tr("agents.message.reply"), height: 22, width: 22) {
                            replyToAnswer(AnswerReply.source(answer: text, selection: SelectableProse.selection(in: NSApp.keyWindow)))
                        }
                    }
                    actions()
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .task(id: footer && fileLinkBase != nil ? text : "") {
            guard footer, !text.isEmpty else { return }
            let found = await AnswerFiles.load(text, date: date, base: fileLinkBase, side: side)
            // A cancelled look (the answer streamed on) keeps the tiles until the next one is done.
            if !Task.isCancelled { files = found }
        }
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

extension EnvironmentValues {
    /// "Reply" under an agent's final answer: puts the words it is given (the answer, or what you selected of it) as a
    /// quote at the top of the session's composer. Set by each session view for its own composer; nil (no Reply button)
    /// where nothing can be answered.
    @Entry var replyToAnswer: ((String) -> Void)? = nil
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
            CopyIconButton(tr("button.copy"), height: 22, showing: $copied) { text }
            if !trailing { ReadAloudButton(text: text) }
            actions()
            if !trailing, let date { TranscriptTime(date: date).padding(.leading, NookTheme.Spacing.xs) }
        }
        // The icons line up with the text above them, not their own hover fill.
        .padding(trailing ? .trailing : .leading, -NookTheme.Spacing.xs)
        .opacity(visible || copied ? 1 : 0)
        .animation(NookTheme.hover, value: visible)
    }
}

/// Reads an answer aloud with the on-device voice (`SpeechOutput`); a second press stops it. In every conversation's
/// reply footer, so every agent and chat answer has it.
struct ReadAloudButton: View {
    let text: String
    @State private var speaking = false

    var body: some View {
        ToolbarIconButton(speaking ? "stop.fill" : "speaker.wave.2",
                          speaking ? tr("agents.message.stopReading") : tr("agents.message.readAloud"),
                          height: 22, width: 22) {
            let speech = AppModel.shared.speech
            if speech.isSpeaking {
                speech.stop()
                speaking = false
            } else {
                speech.speak(text, language: AppModel.shared.settings.language)
                speaking = true
            }
        }
    }
}
