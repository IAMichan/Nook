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
                MessageTicksMark(ticks: ticks)
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
                    MessageTicksMark(ticks: ticks)
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

/// What a chat's app says about the chat, under its name in the Chats tab, the same for every app: "5 members" for a
/// group (or "Info" for a person with something to tell), which opens its info: a group's description (who set it),
/// when and by whom it was made, who may write and edit, and its people with their admins marked; a person's bio, username,
/// number, address and job title. Only what the app said is shown (`ChatProfile`).
struct ChatInfoButton: View {
    let name: String
    let members: [String]
    let profile: ChatProfile?
    let isGroup: Bool
    let appName: String
    @State private var open = false
    @State private var hovering = false

    private var sorted: [String] {
        // Admins first, then everyone else, each by name.
        let admins = Set(profile?.admins ?? [])
        return members.sorted { a, b in
            let (aAdmin, bAdmin) = (admins.contains(a), admins.contains(b))
            if aAdmin != bAdmin { return aAdmin }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Whether there is anything to show: a group's people or count, or anything its app said.
    static func shows(members: [String]?, profile: ChatProfile?) -> Bool {
        !(members ?? []).isEmpty || !(profile?.isEmpty ?? true)
    }

    private var label: String {
        if isGroup {
            let count = members.isEmpty ? (profile?.memberCount ?? 0) : members.count
            if count > 0 { return tr("chats.members", count) }
        }
        return tr("chats.info")
    }

    var body: some View {
        Button { open = true } label: {
            Text(label)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                .underline(hovering)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(tr(isGroup ? "chats.info.group" : "chats.info.person"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                ChatInfoPanel(name: name, members: sorted, profile: profile ?? ChatProfile(), isGroup: isGroup, appName: appName)
                    .padding(NookTheme.Spacing.lg)
            }
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: 460)
        }
    }
}

/// The info itself, inside `ChatInfoButton`'s popover.
struct ChatInfoPanel: View {
    let name: String
    let members: [String]
    let profile: ChatProfile
    let isGroup: Bool
    let appName: String

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func person(_ name: String) -> String { name == ChatMembership.me ? tr("chat.you") : name }

    /// "Created by Anna on 12 Mar 2024", as far as the app says.
    private var createdLine: String? {
        let when = profile.created.map { Self.day.string(from: $0) }
        switch (profile.createdBy.map(person), when) {
        case let (who?, when?): return tr("chats.info.createdBy", who, when)
        case let (who?, nil): return tr("chats.info.createdByOnly", who)
        case let (nil, when?): return tr("chats.info.created", when)
        default: return nil
        }
    }

    /// What the app says of the chat besides its people, one line each.
    private var facts: [(label: String, value: String)] {
        [(tr("chats.info.ownName"), profile.ownName), (tr("chats.info.username"), profile.username),
         (tr("chats.info.phone"), profile.phone), (tr("chats.info.email"), profile.email),
         (tr("chats.info.jobTitle"), profile.title), (tr("chats.info.business"), profile.business),
         (tr("chats.info.category"), profile.category), (tr("chats.info.address"), profile.address),
         (tr("chats.info.website"), profile.website), (tr("chats.info.location"), profile.location),
         (tr("chats.info.timeZone"), profile.timeZone), (tr(isGroup ? "chats.info.inviteLink" : "chats.info.link"), profile.link)]
            .compactMap { pair in pair.1.flatMap(ChatProfile.text).map { (pair.0, $0) } }
    }

    private var rules: [String] {
        [profile.verified == true ? tr("chats.info.verified") : nil, profile.bot == true ? tr("chats.info.bot") : nil,
         profile.blocked == true ? tr("chats.info.blocked") : nil,
         profile.adminsOnly == true ? tr("chats.info.adminsOnly") : nil, profile.locked == true ? tr("chats.info.locked") : nil,
         profile.disappearAfter.flatMap { $0 > 0 ? tr("chats.info.disappearing", ChatGroupChange.duration($0)) : nil }]
            .compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(name)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .accessibilityAddTraits(.isHeader)
                Text(tr(isGroup ? "chats.info.group" : "chats.info.person") + " · " + appName)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
            }
            if let about = ChatProfile.text(profile.about) {
                section(tr(isGroup ? "chats.info.description" : "chats.info.about")) {
                    ChatMessageText(text: about)
                        .foregroundStyle(NookTheme.paper)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let by = profile.aboutBy {
                        Text(tr("chats.info.setBy", person(by)) + (profile.aboutSince.map { " · " + Self.day.string(from: $0) } ?? ""))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
            }
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    ForEach(facts, id: \.label) { fact in
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(fact.label)
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.textTertiary)
                            // Through the chat's own text, so a link or an address in it opens.
                            ChatMessageText(text: fact.value)
                                .foregroundStyle(NookTheme.paper)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if createdLine != nil || !rules.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    ForEach([createdLine].compactMap { $0 } + rules, id: \.self) { line in
                        Text(line)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
            }
            if !members.isEmpty {
                section(tr("chats.info.memberCount", members.count)) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                            HStack(spacing: NookTheme.Spacing.md) {
                                ChatPersonBadge(name: member)
                                Text(member)
                                    .font(NookTheme.TextStyle.body)
                                    .foregroundStyle(NookTheme.paper)
                                    .lineLimit(1)
                                Spacer(minLength: NookTheme.Spacing.sm)
                                if profile.admins?.contains(member) == true {
                                    Text(tr("chats.info.admin"))
                                        .font(NookTheme.TextStyle.caption)
                                        .foregroundStyle(NookTheme.mint)
                                }
                            }
                        }
                    }
                }
            } else if let count = profile.memberCount, count > 0 {
                Text(tr("chats.info.memberCount", count))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
            }
            if profile.isEmpty && members.isEmpty {
                Text(tr("chats.info.nothing", appName))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(title)
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// A person in a list of a chat's people: their initials on the same tint their name has in the group's bubbles.
struct ChatPersonBadge: View {
    let name: String
    var size: CGFloat = 22

    /// Each person's own color in a chat, the same every time: their name in a group's bubbles, their initials.
    static func tint(for name: String) -> Color { ChatPersonTint.color(for: name) }

    var body: some View {
        ChatInitialsFace(name: name, initials: WAJID.initials(name), size: size, scale: 0.4)
            .accessibilityHidden(true)
    }
}

/// Who wrote a group message, beside its bubble: their photo in Contacts, else their initials on their own tint (the
/// color of their name above the bubble). The same for every chat app, since each names a group message's sender. It
/// watches the photos itself, so one that comes in redraws the faces only, not the bubbles.
struct ChatSenderFace: View {
    let name: String
    var size: CGFloat = 28
    @ObservedObject private var photos = ContactPhotos.shared

    var body: some View {
        Group {
            if let photo = photos.photo(handle: nil, name: name) {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ChatInitialsFace(name: name, initials: WAJID.initials(name), size: size)
            }
        }
        .help(name)
        .accessibilityHidden(true)
    }
}
