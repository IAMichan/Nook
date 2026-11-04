import SwiftUI

// The pieces every conversation with Nook or an agent shares, on the Mac (`TranscriptUserMessage`, `TranscriptReply`
// in TranscriptMessage.swift) and on the iPhone (the same two in MessageViews.swift): the measurements, your bubble on
// the right, how a long message folds, and the time under a message.

/// The measurements every conversation shares, so the Nook chat and the agents read alike on both platforms.
enum TranscriptStyle {
    /// The size of the words of a message on the Mac; the phone follows Dynamic Type (`TextStyle.body`).
    static let textSize: CGFloat = 14
    /// The room above each of your messages: every turn starts as a block of its own.
    static let turnGap = NookTheme.Spacing.xxl
    /// Your words stay narrower than the answer, so the thread reads as a conversation at a glance; a little less on
    /// the narrow phone.
    static let bubbleInset: CGFloat = SharedMetrics.isPhone ? 56 : 64
    /// A message of yours longer than this folds to its first lines, with "Show full message" under it.
    static let foldCharacters = 600
    static let foldLines = 8
    /// How tall a folded message of yours is.
    static let foldedHeight: CGFloat = 176
    /// The column a work line's icon sits in, and how far what a line opens to (a thought, a command's output) is
    /// indented: to the words of the line above it.
    static let workIcon: CGFloat = 24
    static let workIndent: CGFloat = workIcon + NookTheme.Spacing.sm

    /// Whether a message of yours is long enough to fold.
    static func isLong(_ text: String) -> Bool {
        text.count > foldCharacters || text.split(separator: "\n", omittingEmptySubsequences: false).count > foldLines
    }
}

/// What you wrote, as a soft bubble on the right of the conversation: the room on its left, the padding that keeps a
/// second line clear of the round corners, and the bubble's fill. What goes in it (the words, "Show full message") is
/// the caller's.
struct TranscriptUserBubble<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: TranscriptStyle.bubbleInset)
            content()
                .padding(.horizontal, NookTheme.Spacing.xl)
                .padding(.vertical, NookTheme.Spacing.lg)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.bubble, style: .continuous).fill(NookTheme.bubble))
        }
    }
}

extension View {
    /// A long message of yours folded to its first lines, fading out at the bottom.
    @ViewBuilder
    func transcriptFolded(_ folded: Bool) -> some View {
        if folded {
            frame(maxHeight: TranscriptStyle.foldedHeight, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
        } else {
            self
        }
    }
}

/// "14:03" today, "12 Oct 14:03" before; on the Mac the full date on hover.
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
