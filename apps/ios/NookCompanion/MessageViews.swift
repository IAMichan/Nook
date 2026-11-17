import SwiftUI
import UIKit

// The messages of every conversation on the phone, one place for all of them, built on the parts shared with the Mac
// (apps/macos/UI/Shared: `ChatListRowContent`, `ChatBubbleShape`, `ChatDayDivider`, `ChatQuote`,
// `MessageTicksMark`, `ChatTypingBubble`, `TranscriptStyle`, `TranscriptUserBubble`, `TranscriptTime`):
//
// - A conversation with Nook or an agent (the Nook tab, a session's transcript): what you wrote is a soft bubble on
//   the right (`TranscriptUserMessage`), the answer formatted text on the left without a bubble (`TranscriptReply`).
// - A conversation in a chat app (the Chats tab): bubbles with a tail, yours on the right and theirs on the left, in
//   runs per person, the day between them (`ChatBubbleView`).
//
// What is here is what the phone does differently: a long press instead of hover, Dynamic Type, a finger-sized row.
// Never draw a message by hand in a screen.

// MARK: Nook and the agents

/// What you wrote: a soft bubble on the right, a long message folded to its first lines, and under it its time. Sent
/// while the agent worked, a quiet "Steered" mark sits above it; still on the phone (`pending`), it is dimmed and says
/// so where its time goes. A long press copies it.
struct TranscriptUserMessage: View {
    let text: String
    var date: Date? = nil
    /// Sent while the agent was working: it changed course mid-turn.
    var steered = false
    /// Written on the phone and waiting for the Mac (`CompanionOutbox`).
    var pending = false
    @State private var expanded = false

    private var long: Bool { TranscriptStyle.isLong(text) }

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            if steered {
                Label("Steered", systemImage: "arrow.turn.down.right")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            TranscriptUserBubble {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    // A message that starts with a quote (a reply to an answer) shows it as a card above your words.
                    let lead = AnswerReply.leadingQuote(text)
                    let words = lead?.rest ?? text
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if let lead { TranscriptQuoteCard(text: lead.quote) }
                        if !words.isEmpty {
                            Text(verbatim: words)
                                .font(Theme.TextStyle.body)
                                .foregroundStyle(Theme.paper)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transcriptFolded(long && !expanded)
                    if long {
                        Button(expanded ? String(localized: "Show less") : String(localized: "Show all")) {
                            withAnimation(Theme.reveal) { expanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.TextStyle.label)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .contextMenu { MessageCopyButton(text: text) }
            .opacity(pending ? 0.6 : 1)
            if pending {
                Label("Not sent yet · waiting for your Mac", systemImage: "clock")
                    .font(Theme.TextStyle.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else if let date {
                TranscriptTime(date: date)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The answer: formatted text on the left without a bubble, then what came with it (`extras`), and its time under a
/// final answer. A long press copies it.
struct TranscriptReply<Extras: View>: View {
    let text: String
    var date: Date? = nil
    var failed = false
    /// The time under the answer; only the final answer of a turn has it.
    var footer = true
    @ViewBuilder var extras: () -> Extras
    @Environment(\.replyToAnswer) private var replyToAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !text.isEmpty {
                // Headings, lists, code and tables as blocks, with diagrams and math drawn as on the Mac.
                MarkdownBlocksView(text: text, color: failed ? Theme.coral : Theme.textStrong)
                    .contextMenu {
                        MessageCopyButton(text: text)
                        // As "Reply" under an answer on the Mac: a quote of it at the top of the session's composer.
                        if let replyToAnswer {
                            Button { replyToAnswer(text) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        }
                    }
            }
            extras()
            if footer, !text.isEmpty, let date {
                // Under a turn's final answer: its time and Copy.
                HStack(spacing: Theme.Spacing.sm) {
                    TranscriptTime(date: date)
                    Button {
                        UIPasteboard.general.string = text
                        Haptics.tap()
                    } label: {
                        Image(icon: "doc.on.doc")
                            .font(Theme.TextStyle.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFade())
                    .accessibilityLabel(Text("Copy"))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TranscriptReply where Extras == EmptyView {
    init(text: String, date: Date? = nil, failed: Bool = false, footer: Bool = true) {
        self.init(text: text, date: date, failed: failed, footer: footer) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// "Reply" in an answer's long-press menu: puts the answer as a quote at the top of the session's composer. Set by
    /// the session's screen where you can write to it; nil (no Reply) elsewhere.
    @Entry var replyToAnswer: ((String) -> Void)? = nil
}

/// The quote a message of yours starts with (`AnswerReply.leadingQuote`), as an inset card at the top of your bubble,
/// as on the Mac: a bar and the quoted words, quieter than yours, at most a few lines.
struct TranscriptQuoteCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Markdown.text(text)
                .font(Theme.TextStyle.detail)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.leading, Theme.Spacing.lg)
        .padding(.trailing, Theme.Spacing.md)
        .overlay(alignment: .leading) {
            Capsule().fill(Theme.textTertiary).frame(width: 3)
                .padding(.vertical, Theme.Spacing.sm).padding(.leading, Theme.Spacing.xs)
        }
        .roundedBackground(Theme.wash.opacity(0.05), radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
    }
}

/// Copy, in a message's long-press menu.
struct MessageCopyButton: View {
    let text: String

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            Haptics.tap()
        } label: { Label("Copy", systemImage: "doc.on.doc") }
    }
}

enum Markdown {
    /// Inline Markdown (bold, code, links) with the line breaks kept; plain text when it does not parse. Links are
    /// `Theme.blue`, as on the Mac.
    static func text(_ source: String) -> Text {
        if var styled = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in styled.runs where run.link != nil { styled[run.range].foregroundColor = Theme.blue }
            return Text(styled)
        }
        return Text(verbatim: source)
    }
}

// MARK: Chat apps

/// Where each message of a chat stands in its run, as the Mac's `ChatTimeline`: messages one person sends within a few
/// minutes of each other sit close together, the first with their name and the bubble's tail, the last with the room
/// below it.
enum ChatRuns {
    /// How far apart two messages of one person may be and still read as one run.
    static let gap: TimeInterval = 5 * 60

    static func sameRun(_ a: InboxLine?, _ b: InboxLine?) -> Bool {
        guard let a, let b else { return false }
        guard a.fromMe == b.fromMe, a.sender == b.sender else { return false }
        let first = Date(timeIntervalSince1970: a.date), second = Date(timeIntervalSince1970: b.date)
        return Calendar.current.isDate(first, inSameDayAs: second) && abs(second.timeIntervalSince(first)) <= gap
    }

    static func newDay(_ line: InboxLine, after previous: InboxLine?) -> Bool {
        guard let previous else { return true }
        return !Calendar.current.isDate(Date(timeIntervalSince1970: line.date), inSameDayAs: Date(timeIntervalSince1970: previous.date))
    }

    /// Each person in a group writes in a color of their own, the same every time and on the Mac (`ChatPersonTint`).
    static func tint(for name: String) -> Color { ChatPersonTint.color(for: name) }
}

/// A message of a chat app, the Mac's `ChatBubbleView`: yours on `chatMine` on the right, theirs on `chatTheirs` on
/// the left with who wrote it (in their own color) on the first of a run; the message it answers quoted at its top, the
/// time and your ticks at its bottom right, and the emoji people put on it under it. A message of only emoji stands
/// without a bubble, large.
struct ChatBubbleView: View {
    let line: InboxLine
    /// The first of a run by one person: their name above it (in a group) and the bubble's tail.
    var first = true
    /// The last of a run: more room under it.
    var last = true
    /// Written on the phone and waiting for the Mac: dimmed, with a clock for its time.
    var pending = false
    /// Opens your message's info from its ticks (who has it and who read it); nil when the app says nothing per person.
    var onInfo: (() -> Void)? = nil
    /// The message's photo from the Mac (`ChatMediaStore`), and what a tap on it does (enlarge it).
    var photo: UIImage? = nil
    var onPhoto: (() -> Void)? = nil
    /// A vote on its poll, where the chat's app takes one (`InboxAbility.vote`).
    var onVote: ((String) -> Void)? = nil
    /// A tap on an emoji under it: yours again takes it back, another one adds yours (`InboxAbility.react`).
    var onReaction: ((String) -> Void)? = nil

    /// The widest a bubble gets: a long message wraps into lines that are easy to read.
    static let inset: CGFloat = 48

    /// A file that shows as a picture: a photo, a video's first frame, a GIF, a sticker.
    private var pictured: Bool { ["photo", "video", "gif", "sticker"].contains(line.media ?? "") && line.deleted != true }

    private var emojiOnly: Bool {
        line.attachment == nil && line.poll == nil && line.quoteText == nil && !line.text.isEmpty && line.text.count <= 3
            && line.text.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmojiModifier
                || $0.value == 0x200D || $0.value == 0xFE0F }
    }

    /// "0:42" or "1:05:10": how long a voice message lasts; nil when its app did not say.
    static func length(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    var body: some View {
        if line.notice == true {
            // Someone came in or left, or the group changed: a centred line, as on the Mac (`ChatMembershipLine`).
            Text(verbatim: line.text)
                .font(Theme.TextStyle.caption)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.surface, in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xs)
        } else {
            message
        }
    }

    private var message: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            if line.fromMe { Spacer(minLength: Self.inset) }
            // In a group, who wrote it shows beside each of their messages, as on the Mac.
            if !line.fromMe, !line.sender.isEmpty {
                ChatInitialsFace(name: line.sender, initials: InboxAvatar.initials(line.sender), size: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: line.fromMe ? .trailing : .leading, spacing: Theme.Spacing.xxs) {
                // The reactions under the bubble at its leading side, overlapping only its bottom edge, so they never
                // cover the text or the time. (Aligned in an overlay they sat on the bubble's last line instead.)
                VStack(alignment: .leading, spacing: line.reactions.isEmpty ? 0 : -Theme.Spacing.sm) {
                    bubble.opacity(pending ? 0.6 : 1)
                    if !line.reactions.isEmpty {
                        reactions
                    }
                }
                // Said in words, not only with a clock: this one has not left the phone.
                if pending {
                    Label("Not sent yet · waiting for your Mac", systemImage: "clock")
                        .font(Theme.TextStyle.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if !line.fromMe { Spacer(minLength: Self.inset) }
        }
        .padding(.top, first ? Theme.Spacing.sm : 0)
        .padding(.bottom, last ? Theme.Spacing.xs : 0)
    }

    @ViewBuilder
    private var bubble: some View {
        if emojiOnly {
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                Text(verbatim: line.text).font(Theme.font(40))
                stamp
            }
            .padding(.horizontal, ChatBubbleShape.tail)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if first, !line.fromMe, !line.sender.isEmpty {
                    Text(line.sender)
                        .font(Theme.TextStyle.label)
                        .foregroundStyle(ChatRuns.tint(for: line.sender))
                        .lineLimit(1)
                }
                if let quote = line.quoteText, !quote.isEmpty {
                    ChatQuote(sender: line.quoteSender ?? "", text: quote, mine: line.fromMe)
                        .padding(.bottom, Theme.Spacing.xxs)
                }
                if pictured {
                    picture.padding(.vertical, Theme.Spacing.xxs)
                } else if let poll = line.poll, line.deleted != true {
                    InboxPollView(poll: poll, onVote: onVote)
                        .padding(.vertical, Theme.Spacing.xxs)
                } else if let attachment = line.attachment {
                    // A voice or audio message reads with its length, as on the Mac; any other file by its name.
                    let audio = line.media == "audio" || line.media == "voice"
                    HStack(spacing: Theme.Spacing.sm) {
                        Label(attachment, systemImage: audio ? "waveform" : "paperclip")
                        if audio, let length = Self.length(line.seconds) {
                            Text(verbatim: length).monospacedDigit().foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textStrong)
                    .padding(.vertical, Theme.Spacing.xxs)
                }
                // The time sits after the last line, at the bubble's right, as chat apps place it.
                HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.md) {
                    // A poll says its question itself; a deleted message says so, quieter.
                    if !line.text.isEmpty, line.poll == nil || line.deleted == true {
                        Text(verbatim: line.text)
                            .font(Theme.TextStyle.body)
                            .italic(line.deleted == true)
                            .foregroundStyle(line.deleted == true ? Theme.textTertiary : Theme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    stamp
                }
            }
            .padding(.horizontal, Theme.Spacing.md + Theme.Spacing.xxs)
            .padding(.vertical, Theme.Spacing.sm)
            // Room for the tail on its side, on every bubble of the run, so their edges line up.
            .padding(line.fromMe ? .trailing : .leading, ChatBubbleShape.tail)
            .background(ChatBubbleShape(mine: line.fromMe, tailed: first, joinsBelow: !last)
                .fill(line.fromMe ? Theme.chatMine : Theme.chatTheirs))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The photo, the video's first frame, the GIF or the sticker, as the Mac shows it in the bubble; a tile while the
    /// phone does not have it yet. A tap enlarges it.
    @ViewBuilder
    private var picture: some View {
        let width: CGFloat = line.media == "sticker" ? 140 : 230
        Group {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: min(width * 1.25, max(width * 0.6, width * photo.size.height / max(photo.size.width, 1))))
                    .clipped()
            } else {
                ZStack {
                    Rectangle().fill(Theme.surface)
                    Image(icon: line.media == "video" ? "video" : "photo")
                        .font(Theme.font(22))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(width: width, height: width * 0.75)
            }
        }
        .overlay {
            if line.media == "video", photo != nil {
                Image(icon: "play.fill")
                    .font(Theme.font(18, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .roundedClip(Theme.Radius.control)
        .contentShape(Rectangle())
        .onTapGesture { onPhoto?() }
        .accessibilityElement()
        .accessibilityLabel(Text(line.attachment ?? String(localized: "Photo")))
        .accessibilityAddTraits(onPhoto == nil ? [] : .isButton)
    }

    /// When it was sent, and for your own how far it got.
    private var stamp: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if pending {
                Image(icon: "clock").font(Theme.font(10, .semibold))
            } else {
                if line.edited == true, line.deleted != true { Text("edited") }
                Text(Date(timeIntervalSince1970: line.date), format: .dateTime.hour().minute())
                    .monospacedDigit()
                if let ticks = MessageTicks(line.ticks) {
                    if let onInfo {
                        // A tap on the ticks says who read it, who has it, and who does not yet, as on the Mac.
                        Button(action: onInfo) { MessageTicksMark(ticks: ticks) }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Message info"))
                    } else {
                        MessageTicksMark(ticks: ticks)
                    }
                }
            }
        }
        .font(Theme.TextStyle.caption)
        .foregroundStyle(Theme.chatStamp)
        .fixedSize()
    }

    /// The emoji on a message as one pill over the bubble's bottom edge, as on the Mac: each emoji once, the first three,
    /// and how many reacted in all.
    private var reactions: some View {
        // The Mac sends each emoji with its count when more than one put it there: "👍 3".
        let parts = line.reactions.map { reaction -> (emoji: String, count: Int) in
            let words = reaction.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { return (reaction, 1) }
            return (String(words[0]), count)
        }
        let total = parts.reduce(0) { $0 + $1.count }
        let mine = Set(line.myReactions ?? [])
        return HStack(spacing: Theme.Spacing.xxs) {
            HStack(spacing: 0) {
                ForEach(Array(parts.prefix(3).enumerated()), id: \.offset) { _, part in
                    if let onReaction {
                        // A tap on yours takes it back, on another adds yours: as on the Mac's reaction pills.
                        Button { onReaction(part.emoji) } label: { Text(verbatim: part.emoji).font(Theme.font(14)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(mine.contains(part.emoji) ? "Take back \(part.emoji)" : "React with \(part.emoji)"))
                    } else {
                        Text(verbatim: part.emoji).font(Theme.font(14))
                    }
                }
            }
            if total > 1 {
                Text(verbatim: "\(total)")
                    .font(Theme.TextStyle.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(mine.isEmpty ? Theme.chatTheirs : Theme.chatMine, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.canvas, lineWidth: 2))
        .padding(.leading, ChatBubbleShape.tail + Theme.Spacing.sm)
    }
}

extension ChatDayDivider {
    /// Where a new day starts in a chat on the phone: "Today", "Yesterday", the weekday within the last week, else the
    /// date (the Mac's `ChatTimeline.dayLabel`).
    init(date: Date) { self.init(label: Self.label(date)) }

    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0 && days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
