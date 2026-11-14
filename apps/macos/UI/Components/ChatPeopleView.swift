import SwiftUI

/// One card per person across every chat app: their face, the apps they are in (the chat opens from its icon), when you
/// last talked, what is new, a birthday and a note of your own. A birthday today is said once at the top.
struct ChatPeopleView: View {
    @ObservedObject var capture: ChatCaptureService
    @ObservedObject private var store = ChatFollowUpStore.shared
    /// Opens a chat (its key in `ChatInbox`) in the Chats tab.
    let open: (String) -> Void
    @State private var query = ""
    @State private var expanded: String?

    var body: some View {
        let hidden = ChatNoticeRulesStore.shared.rules.hidden
        let people = ChatPeople.search(ChatPeople.people(capture.inbox.threads.values.filter { !hidden.contains($0.id) }), query)
        let today = store.notes.birthdays(on: Date())
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            NookSearchField(prompt: tr("chats.people.search"), text: $query, style: .inline)
                .padding(.horizontal, NookTheme.Spacing.md)
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    if people.isEmpty { ListEmptyNote(tr("chats.people.empty"), padding: NookTheme.Spacing.lg) }
                    ForEach(people.filter { today.contains($0.id) }) { person in
                        Text(tr("chats.people.birthdayToday", person.name))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.iris)
                            .padding(.horizontal, NookTheme.Spacing.lg)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                            if index > 0 { NookDivider() }
                            ChatPersonCard(person: person, expanded: expanded == person.id, open: open) {
                                withAnimation(NookTheme.reveal) { expanded = expanded == person.id ? nil : person.id }
                            }
                        }
                    }
                    .panelCard()
                    .padding(.horizontal, NookTheme.Spacing.md)
                }
            }
        }
        .padding(.top, NookTheme.Spacing.md)
        .accessibilityLabel(tr("chats.people.title"))
    }
}

private struct ChatPersonCard: View {
    let person: ChatPerson
    let expanded: Bool
    let open: (String) -> Void
    let toggle: () -> Void
    @ObservedObject private var store = ChatFollowUpStore.shared
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Button(action: toggle) {
                HStack(spacing: NookTheme.Spacing.md) {
                    ChatSenderFace(name: person.name, picture: person.avatar, size: 34)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(person.name)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textStrong)
                            .lineLimit(1)
                        Text(NookDates.ago(person.lastInteraction))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    Spacer(minLength: NookTheme.Spacing.sm)
                    NookCountBadge(count: person.unread)
                    ForEach(person.chats, id: \.chat) { chat in
                        Button { open(chat.chat) } label: {
                            SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 15, source: chat.app)
                        }
                        .buttonStyle(.nookPlain)
                        .help(MessagingApps.app(id: chat.app)?.name ?? chat.app)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            if expanded {
                TextField(tr("chats.people.notePlaceholder"), text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.detail)
                    .lineLimit(1...4)
                    .padding(NookTheme.Spacing.sm)
                    .background(NookTheme.well)
                    .roundedClip(NookTheme.Radius.control)
                    .onSubmit { store.changeNotes { $0.setNote(note, for: person.id) } }
                    .onChange(of: note) { _, value in store.changeNotes { $0.setNote(value, for: person.id) } }
                    .accessibilityLabel(tr("chats.people.note"))
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .onAppear { note = store.notes.note(for: person.id) }
    }
}
