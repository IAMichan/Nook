import SwiftUI

/// Your own message's info in a group, as WhatsApp shows it: how many read it, then who read it (and when), who has it,
/// and who does not have it yet. Opened from the ticks after a bubble's time, in every chat app that says it per person.
struct MessageInfoView: View {
    let ticks: BubbleTicks
    /// Everyone in the group with how far the message got with them (`ChatReceipts.everyone`).
    let readers: [ChatReader]

    private var read: [ChatReader] { readers.filter { $0.receipt == .read } }
    private var delivered: [ChatReader] { readers.filter { $0.receipt == .delivered } }
    private var waiting: [ChatReader] { readers.filter { $0.receipt < .delivered } }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.sm) {
                TicksView(ticks: ticks)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(tr("chat.info.title"))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Text(tr("chat.info.count", read.count, readers.count))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    section(tr("chat.info.readBy"), read, ticks: .read)
                    section(tr("chat.info.deliveredTo"), delivered, ticks: .delivered)
                    section(tr("chat.info.waiting"), waiting, ticks: .sent)
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(NookTheme.Spacing.lg)
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String, _ people: [ChatReader], ticks: BubbleTicks) -> some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    TicksView(ticks: ticks)
                    Text(title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: 0)
                    Text("\(people.count)")
                        .font(NookTheme.TextStyle.caption)
                        .monospacedDigit()
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                // Two people can share a name: each row is its place in the list.
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    HStack(spacing: NookTheme.Spacing.md) {
                        ChatPersonBadge(name: person.name)
                        Text(person.name)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        if let date = person.date {
                            Text(Self.when(date))
                                .font(NookTheme.TextStyle.caption)
                                .monospacedDigit()
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "14:02" today, else "Yesterday 14:02", "Monday 14:02", "12 Oct 14:02".
    static func when(_ date: Date) -> String {
        let clock = time.string(from: date)
        guard !Calendar.current.isDateInToday(date) else { return clock }
        return ChatTimeline.dayLabel(date, locale: Locale(identifier: I18n.shared.currentLanguage.rawValue)) + " " + clock
    }
}

/// Who is in a group chat, as its app lists them (you left out): "5 members" under the chat's name, which opens the
/// list. Shown in the Chats tab for every app that names a group's people.
struct ChatMembersButton: View {
    let members: [String]
    @State private var open = false
    @State private var hovering = false

    private var sorted: [String] { members.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }

    var body: some View {
        Button { open = true } label: {
            Text(tr("chats.members", members.count))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                .underline(hovering)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(tr("chats.members.title"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(tr("chats.members.title"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        ForEach(Array(sorted.enumerated()), id: \.offset) { _, name in
                            HStack(spacing: NookTheme.Spacing.md) {
                                ChatPersonBadge(name: name)
                                Text(name)
                                    .font(NookTheme.TextStyle.body)
                                    .foregroundStyle(NookTheme.paper)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .padding(NookTheme.Spacing.lg)
            .frame(width: 240, alignment: .leading)
        }
    }
}

/// A person in a list of a chat's people: their initials on the same tint their name has in the group's bubbles.
struct ChatPersonBadge: View {
    let name: String
    var size: CGFloat = 22

    private static let colors: [Color] = [NookTheme.mint, NookTheme.blue, NookTheme.violet, NookTheme.music]

    /// Each person's own color in a chat, the same every time: their name in a group's bubbles, their initials.
    static func tint(for name: String) -> Color {
        colors[ChatTimeline.colorIndex(for: name, count: colors.count)]
    }

    var body: some View {
        let tint = Self.tint(for: name)
        Circle()
            .fill(tint.opacity(0.16))
            .overlay(
                Text(WAJID.initials(name))
                    .font(NookTheme.rounded(size * 0.4, .semibold))
                    .foregroundStyle(tint)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
