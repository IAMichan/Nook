import SwiftUI

/// "What do I owe, and what am I waiting for?" for every chat app at once: the chats whose last word is theirs and
/// waited a while, and the chats you marked "waiting for reply". One row per chat with its app's icon and the person's
/// face; a click opens the chat, and each row can be snoozed or settled. Nothing is sent from here.
struct ChatFollowUpView: View {
    @ObservedObject var capture: ChatCaptureService
    @ObservedObject private var store = ChatFollowUpStore.shared
    /// Opens the chat (its key in `ChatInbox`) in the Chats tab.
    let open: (String) -> Void

    var body: some View {
        let now = Date()
        let turns = ChatFollowUpStore.turns(of: capture.inbox).filter { !ChatNoticeRulesStore.shared.rules.isHidden($0.chat) }
        let owed = store.follow.owed(turns, now: now)
        let waiting = turns.filter { store.follow.isWaiting($0.chat) }
            .sorted { (store.follow.waiting[$0.chat]?.since ?? now) < (store.follow.waiting[$1.chat]?.since ?? now) }
        ScrollView {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                if owed.isEmpty && waiting.isEmpty {
                    ListEmptyNote(tr("chats.followUp.empty"), padding: NookTheme.Spacing.lg)
                }
                if !owed.isEmpty {
                    group(title: tr("chats.followUp.owed"), turns: owed, now: now, waiting: false)
                }
                if !waiting.isEmpty {
                    group(title: tr("chats.followUp.waiting"), turns: waiting, now: now, waiting: true)
                }
            }
            .padding(.vertical, NookTheme.Spacing.md)
        }
        .accessibilityLabel(tr("chats.followUp.title"))
    }

    private func group(title: String, turns: [ChatFollowUpTurn], now: Date, waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack {
                NookSectionLabel(title)
                NookCountBadge(count: turns.count)
            }
            VStack(spacing: 0) {
                ForEach(Array(turns.enumerated()), id: \.element.chat) { index, turn in
                    if index > 0 { NookDivider() }
                    ChatFollowUpRow(turn: turn, now: now, waiting: waiting, open: open)
                }
            }
            .panelCard()
            .padding(.horizontal, NookTheme.Spacing.md)
        }
    }
}

/// One chat in the follow-up list: who, where, what they said last and how long ago, with the ways to deal with it.
private struct ChatFollowUpRow: View {
    let turn: ChatFollowUpTurn
    let now: Date
    let waiting: Bool
    let open: (String) -> Void
    @ObservedObject private var store = ChatFollowUpStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            ChatSenderFace(name: turn.name, picture: ChatCaptureService.shared.inbox.threads[turn.chat]?.avatar, size: 30)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(turn.name)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textStrong)
                        .lineLimit(1)
                    SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textTertiary, size: 12, source: turn.app)
                }
                Text(turn.lastText.isEmpty ? " " : turn.lastText)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            Text(since)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(waiting ? NookTheme.amber : NookTheme.textTertiary)
                .lineLimit(1)
            menu
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .background(hovering ? NookTheme.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .nookClickable()
        .onTapGesture { open(turn.chat) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// How long it has waited: for their word, from when they wrote; for yours, from when you marked the chat.
    private var since: String {
        let from = waiting ? store.follow.waiting[turn.chat]?.since : turn.date
        return from.map { NookDates.ago($0, now: now) } ?? ""
    }

    private var menu: some View {
        Menu {
            if waiting {
                Button(tr("chats.followUp.clearWaiting")) { store.change { $0.clearWaiting(chat: turn.chat) } }
            } else {
                Button(tr("chats.followUp.markWaiting")) { store.change { $0.markWaiting(chat: turn.chat, now: Date()) } }
            }
            Divider()
            ForEach(ChatLaterOption.allCases) { option in
                Button(tr("chats.snooze." + option.rawValue)) {
                    store.change { $0.snooze(chat: turn.chat, until: option.date(from: Date())) }
                }
            }
        } label: {
            Image(icon: "ellipsis")
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.nookBorderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(tr("chats.snooze"))
    }
}
