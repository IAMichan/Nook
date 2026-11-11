import SwiftUI
import UIKit

// WhatsApp's own look on the phone, for a chat that is a WhatsApp chat (`InboxChatDigest.app == "whatsapp"`): its dark
// colors, its bubbles with the small tail, the day in a pill, the list's row, the header and the composer's pill with the
// round green button. Only the phone has this; the Mac's views (apps/macos) are not touched and stay Nook's own. Every
// other chat app keeps Nook's look, and what a bubble or a row says (text, time, ticks, count) is the same data either way.

enum WhatsAppLook {
    /// The chat's background, behind the bubbles.
    static let wallpaper = Color(hex: 0x0B141A)
    /// The bars and everything that stands out from the wallpaper: their bubbles, the composer's pill, the header.
    static let bar = Color(hex: 0x1F2C34)
    static let mine = Color(hex: 0x005C4B)
    static let theirs = Color(hex: 0x1F2C34)
    static let text = Color(hex: 0xE9EDEF)
    static let quiet = Color(hex: 0x8696A0)
    static let stampOnMine = Color(hex: 0x8DB5AC)
    /// The green of the send button, a new chat's count and the time of a chat with something new.
    static let green = Color(hex: 0x00A884)
    static let readTick = Color(hex: 0x53BDEB)
    static let dayPill = Color(hex: 0x182229)
    static let separator = Color(hex: 0x222D34)

    static func isWhatsApp(_ app: String?) -> Bool { app == "whatsapp" }
}

// MARK: Bubbles

/// WhatsApp's bubble: softly rounded, with a small tail at the top corner of the first message of a run.
struct WhatsAppBubbleShape: Shape {
    let mine: Bool
    let tailed: Bool
    static let tail: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 9
        let body = CGRect(x: mine ? rect.minX : rect.minX + Self.tail, y: rect.minY,
                          width: max(0, rect.width - Self.tail), height: rect.height)
        let top: CGFloat = tailed ? 0 : radius
        var path = Path(roundedRect: body, cornerRadii: RectangleCornerRadii(
            topLeading: mine ? radius : top, bottomLeading: radius,
            bottomTrailing: radius, topTrailing: mine ? top : radius), style: .continuous)
        guard tailed else { return path }
        let edge = mine ? body.maxX : body.minX
        let tip = mine ? rect.maxX : rect.minX
        var tail = Path()
        tail.move(to: CGPoint(x: edge, y: body.minY))
        tail.addLine(to: CGPoint(x: tip, y: body.minY))
        tail.addQuadCurve(to: CGPoint(x: edge, y: body.minY + 11), control: CGPoint(x: edge + (mine ? 1 : -1) * 1, y: body.minY + 3))
        tail.closeSubpath()
        path.addPath(tail)
        return path
    }
}

/// Your ticks as WhatsApp draws them: a clock, one grey tick, two grey, two in its light blue, or failed.
struct WhatsAppTicksMark: View {
    let ticks: MessageTicks
    /// The grey a tick has on this background: lighter on your own green bubble.
    var rest: Color = WhatsAppLook.quiet

    var body: some View {
        Group {
            switch ticks {
            case .pending: Image(icon: "clock").font(Theme.font(10.5, .semibold))
            case .sent: check
            case .delivered, .read:
                ZStack(alignment: .leading) {
                    check
                    check.padding(.leading, 5)
                }
            case .failed: Image(icon: "exclamationmark.circle.fill").font(Theme.font(11.5, .semibold))
            }
        }
        .foregroundStyle(ticks == .read ? WhatsAppLook.readTick : (ticks == .failed ? Theme.coral : rest))
        .accessibilityElement()
        .accessibilityLabel(ticks.label)
    }

    private var check: some View { Image(icon: "checkmark").font(Theme.font(10.5, .bold)) }
}

/// Where a new day starts, in WhatsApp's pill centered on the wallpaper.
struct WhatsAppDayPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Theme.font(12.5, .medium))
            .foregroundStyle(WhatsAppLook.quiet)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
            .background(WhatsAppLook.dayPill, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: The list

/// A WhatsApp chat in the list: a round picture, the name and the time on the first line (the time green while something
/// is new), your ticks and the newest message on the second, and the green count on the right.
struct WhatsAppRow: View {
    let chat: InboxChatDigest
    @ObservedObject private var pictures = ChatPictures.shared

    private var when: String {
        let date = Date(timeIntervalSince1970: chat.last)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : ChatDayDivider.label(date)
    }

    var body: some View {
        let unread = chat.unread > 0
        HStack(spacing: Theme.Spacing.lg) {
            InboxAvatar(name: chat.name, app: chat.app, size: 52, picture: pictures.image(for: chat), showsBadge: false)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(chat.name)
                        .font(Theme.font(17, .medium))
                        .foregroundStyle(WhatsAppLook.text)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xs)
                    Text(when)
                        .font(Theme.font(12))
                        .monospacedDigit()
                        .foregroundStyle(unread ? WhatsAppLook.green : WhatsAppLook.quiet)
                        .fixedSize()
                }
                HStack(spacing: Theme.Spacing.xs) {
                    if let typing = InboxTyping.text(chat.typing ?? []) {
                        Text(typing).font(Theme.font(15)).foregroundStyle(WhatsAppLook.green).lineLimit(1)
                    } else {
                        if let ticks = MessageTicks(chat.ticks) { WhatsAppTicksMark(ticks: ticks) }
                        Text(chat.preview.isEmpty ? chat.appName : chat.preview)
                            .font(Theme.font(15))
                            .foregroundStyle(WhatsAppLook.quiet)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Theme.Spacing.xs)
                    if unread {
                        Text(verbatim: chat.unread > 99 ? "99+" : "\(chat.unread)")
                            .font(Theme.font(12, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(WhatsAppLook.wallpaper)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(WhatsAppLook.green, in: Capsule())
                            .accessibilityLabel(Text("\(chat.unread) unread"))
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(Rectangle())
    }
}

// MARK: The composer

/// WhatsApp's composer: a wide rounded pill for the message on the bar's color, and one round green button that sends.
/// While nothing is typed the microphone (dictation) sits in the pill instead.
struct WhatsAppComposer: View {
    @Binding var text: String
    var sending = false
    let onSend: () -> Void
    @FocusState private var focused: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                TextField("Message", text: $text, axis: .vertical)
                    .font(Theme.font(17))
                    .foregroundStyle(WhatsAppLook.text)
                    .tint(WhatsAppLook.green)
                    .lineLimit(1...6)
                    .focused($focused)
                    .frame(minHeight: 28)
                if isEmpty { DictationButton(text: $text) }
            }
            .padding(.leading, Theme.Spacing.xl)
            .padding(.trailing, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(WhatsAppLook.bar))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if !isEmpty {
                Button {
                    Haptics.tap()
                    onSend()
                } label: {
                    ZStack {
                        Circle().fill(WhatsAppLook.green)
                        if sending {
                            ProgressView().controlSize(.small).tint(WhatsAppLook.wallpaper)
                        } else {
                            Image(icon: "paperplane.fill").font(Theme.font(17, .semibold)).foregroundStyle(WhatsAppLook.wallpaper)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(PressFade())
                .disabled(sending)
                .accessibilityLabel("Send")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .animation(Theme.reveal, value: isEmpty)
    }
}

// MARK: The chat's frame

extension View {
    /// The screen of a chat: WhatsApp's wallpaper and header color for a WhatsApp chat, Nook's canvas for any other.
    @ViewBuilder
    func chatScreen(whatsApp: Bool) -> some View {
        if whatsApp {
            self
                .background(WhatsAppLook.wallpaper.ignoresSafeArea())
                .scrollContentBackground(.hidden)
                .toolbarBackground(WhatsAppLook.bar, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self.screen()
        }
    }
}
