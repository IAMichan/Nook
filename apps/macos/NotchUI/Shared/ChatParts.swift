import SwiftUI

// The pieces of a chat app's conversation, the same on the Mac (`ChatTranscript`, the Chats tab) and on the iPhone (its
// Chats tab): a chat's row in the list, the bubble's outline, where a day starts, the message a bubble answers, your
// ticks, and someone typing. What only the Mac does with them (hover buttons, menus, media) stays in ChatTranscript.

// MARK: The list

/// A chat in a list, the Mac's `ChatsRow` and the iPhone's `InboxRow`: its face, its name and when on the first line,
/// the newest message on the second (after your ticks, or who is typing in its place), and where it stands at the end
/// of that line (`trailing`: the count of what is new, a read mark). Something new sets the name in paper and the time
/// in amber. The caller adds what the platform does with a row: a click and hover on the Mac, a tap and a long press
/// on the phone.
struct ChatListRowContent<Avatar: View, Trailing: View>: View {
    let name: String
    /// "14:03" today, else the day ("Yesterday", "Monday", "12 Oct").
    let when: String
    let preview: String
    var unread = false
    /// Your own newest message: how far it got, in front of it.
    var ticks: MessageTicks? = nil
    /// Who types in this chat ("Jan is typing…"), in place of its newest message.
    var typing: String? = nil
    /// A quiet word beside the time (the WhatsApp account while more than one is linked).
    var detail: String? = nil
    /// Hides the time and the detail, where a hover button takes their place (the Mac).
    var hidesTime = false
    @ViewBuilder var avatar: () -> Avatar
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: SharedMetrics.isPhone ? NookTheme.Spacing.lg : NookTheme.Spacing.md) {
            avatar()
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Text(name)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(unread ? NookTheme.paper : NookTheme.textStrong)
                        .lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    if let detail {
                        Text(detail)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .opacity(hidesTime ? 0 : 1)
                    }
                    // Something new: its time in the color of what waits on you, as the count under it.
                    Text(when)
                        .font(NookTheme.TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(unread ? NookTheme.amber : NookTheme.textTertiary)
                        .fixedSize()
                        .opacity(hidesTime ? 0 : 1)
                }
                HStack(spacing: NookTheme.Spacing.sm) {
                    if let typing {
                        Text(typing)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.mint)
                            .lineLimit(1)
                    } else {
                        if let ticks { MessageTicksMark(ticks: ticks) }
                        Text(preview)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(unread ? NookTheme.textStrong : NookTheme.textSecondary)
                            .lineLimit(SharedMetrics.isPhone ? 2 : 1)
                    }
                    Spacer(minLength: NookTheme.Spacing.xs)
                    trailing().fixedSize()
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, SharedMetrics.rowVertical)
        .contentShape(Rectangle())
    }
}

// MARK: Bubbles

/// A chat app's message bubble: a rounded box (`Radius.chatBubble`) with a small tail at its top corner on the first
/// message of a run, filled `chatMine` (yours) or `chatTheirs`. Every bubble keeps `tail` points of room on its side so
/// a run lines up; the typing bubble uses it too. Never draw a chat bubble's outline by hand.
struct ChatBubbleShape: Shape {
    let mine: Bool
    /// The first message of a run: the tail, and a square top corner on the writer's side.
    let tailed: Bool
    /// Another message of the same run follows: its bottom edge meets it.
    var joinsBelow = false
    /// It follows another message of the same run (any but the first): its top edge meets it.
    var joinsAbove: Bool { !tailed }
    static let tail: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let radius = NookTheme.Radius.chatBubble
        let joined = NookTheme.Radius.chatJoin
        let body = CGRect(x: mine ? rect.minX : rect.minX + Self.tail, y: rect.minY,
                          width: max(0, rect.width - Self.tail), height: rect.height)
        // The writer's side: square under the tail, slightly round where it meets the message above or below. The far
        // side stays round: bubbles of a run differ in width there.
        let top: CGFloat = tailed ? 0 : (joinsAbove ? joined : radius)
        let bottom: CGFloat = joinsBelow ? joined : radius
        var path = Path(roundedRect: body, cornerRadii: RectangleCornerRadii(
            topLeading: mine ? radius : top, bottomLeading: mine ? radius : bottom,
            bottomTrailing: mine ? bottom : radius, topTrailing: mine ? top : radius), style: .continuous)
        guard tailed else { return path }
        let edge = mine ? body.maxX : body.minX
        let tip = mine ? rect.maxX : rect.minX
        let depth = min(Self.tail * 1.6, body.height)
        var tailPath = Path()
        tailPath.move(to: CGPoint(x: edge, y: body.minY))
        tailPath.addLine(to: CGPoint(x: tip - (mine ? 1 : -1), y: body.minY))
        tailPath.addQuadCurve(to: CGPoint(x: tip - (mine ? 2 : -2), y: body.minY + 2), control: CGPoint(x: tip, y: body.minY))
        tailPath.addLine(to: CGPoint(x: edge, y: body.minY + depth))
        tailPath.closeSubpath()
        path.addPath(tailPath)
        return path
    }
}

/// Where a new day starts in a chat: "Today", "Yesterday", "Monday", "12 Oct". A small soft label in the middle with
/// room around it, as chat apps mark the day: easy to find while scrolling, quiet while reading.
struct ChatDayDivider: View {
    let label: String

    var body: some View {
        Text(label)
            .font(NookTheme.TextStyle.caption)
            .fontWeight(.semibold)
            .foregroundStyle(NookTheme.textStrong)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.chatTheirs))
            .frame(maxWidth: .infinity)
            .padding(.top, NookTheme.Spacing.xl)
            .padding(.bottom, NookTheme.Spacing.md)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The message a bubble answers, at the bubble's top: a bar, who wrote it and the start of its text; in mint when it
/// answers a message of yours.
struct ChatQuote: View {
    let sender: String
    let text: String
    let mine: Bool
    /// The widest it gets in a wide chat (the Mac's photo width); nil fills the bubble.
    var maxWidth: CGFloat? = nil

    private var tint: Color { mine ? NookTheme.mint : NookTheme.blue }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                if !sender.isEmpty {
                    Text(sender)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(text)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NookTheme.Spacing.xs)
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.md)
        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 3).padding(.vertical, NookTheme.Spacing.xs).padding(.leading, NookTheme.Spacing.xs)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.paper.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Ticks

/// How far your own message got, in every chat app that says it.
enum MessageTicks: Equatable {
    case pending, sent, delivered, read, failed

    /// The words the Mac's bridges and the phone's protocol use ("pending", "sent", "delivered", "read", "failed").
    init?(_ word: String?) {
        switch word {
        case "pending": self = .pending
        case "sent": self = .sent
        case "delivered": self = .delivered
        case "read": self = .read
        case nil: return nil
        default: self = .failed
        }
    }

    var label: String {
        switch self {
        case .pending: return sharedText("whatsapp.ticks.pending", "Sending")
        case .sent: return sharedText("whatsapp.ticks.sent", "Sent")
        case .delivered: return sharedText("whatsapp.ticks.delivered", "Delivered")
        case .read: return sharedText("whatsapp.ticks.read", "Read")
        case .failed: return sharedText("whatsapp.ticks.failed", "Not sent")
        }
    }
}

/// Your message's ticks as the phone's chat apps draw them: a clock, one grey tick, two grey, two blue, or failed.
/// After a bubble's time and in front of a chat's newest message in a list. Never draw ticks by hand.
struct MessageTicksMark: View {
    let ticks: MessageTicks

    var body: some View {
        Group {
            switch ticks {
            case .pending:
                Image(icon: "clock").font(NookTheme.font(10.5, .semibold))
            case .sent:
                check
            case .delivered, .read:
                // The second tick overlaps the first, as on the phone.
                ZStack(alignment: .leading) {
                    check
                    check.padding(.leading, 5)
                }
            case .failed:
                Image(icon: "exclamationmark.circle.fill").font(NookTheme.font(11.5, .semibold))
            }
        }
        .foregroundStyle(color)
        .help(ticks.label)
        .accessibilityElement()
        .accessibilityLabel(ticks.label)
    }

    private var check: some View {
        Image(icon: "checkmark").font(NookTheme.font(10.5, .bold))
    }

    private var color: Color {
        switch ticks {
        case .read: return NookTheme.blue
        case .failed: return NookTheme.coral
        // Grey that still reads on your mint bubble; read is blue, as on the phone.
        case .pending, .sent, .delivered: return NookTheme.chatStamp
        }
    }
}

// MARK: Typing

/// Someone typing, under the chat's last message as WhatsApp shows it: three dots that come and go, and who it is.
struct ChatTypingBubble: View {
    static let id = "\u{1}typing"
    let text: String

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            ChatTypingDots()
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .padding(.leading, ChatBubbleShape.tail)
        .background(ChatBubbleShape(mine: false, tailed: true).fill(NookTheme.chatTheirs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Three dots that light up one after the other while someone types: on the Mac on Nook's own tick grid
/// (`nookTicks`), which keeps the window still between ticks.
struct ChatTypingDots: View {
    var body: some View {
        timeline { date in
            let step = Int(date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: NookTheme.Spacing.xxs) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(NookTheme.textSecondary)
                        .frame(width: SharedMetrics.isPhone ? 6 : 5, height: SharedMetrics.isPhone ? 6 : 5)
                        .opacity(dot == step ? 1 : 0.35)
                }
            }
            .animation(NookTheme.reveal, value: step)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func timeline<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        #if os(macOS)
        TimelineView(.nookTicks(every: 0.3)) { context in content(context.date) }
        #else
        TimelineView(.periodic(from: .now, by: 0.3)) { context in content(context.date) }
        #endif
    }
}

// MARK: Faces

/// Each person's own color in a chat, the same every time and in both apps: their name in a group's bubbles, their
/// initials in a list.
enum ChatPersonTint {
    static let colors: [Color] = [NookTheme.mint, NookTheme.blue, NookTheme.violet, NookTheme.music]

    static func color(for name: String) -> Color {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

/// Someone without a photo: their initials in their own color (`ChatPersonTint`) on a soft circle of it.
struct ChatInitialsFace: View {
    let name: String
    let initials: String
    let size: CGFloat
    /// The initials' size against the circle.
    var scale: CGFloat = 0.36

    var body: some View {
        let tint = ChatPersonTint.color(for: name)
        Circle()
            .fill(tint.opacity(0.16))
            .overlay(
                Text(initials)
                    .font(NookTheme.rounded(size * scale, .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
    }
}
