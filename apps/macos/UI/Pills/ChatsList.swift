import SwiftUI

// The Chats tab's list of chats: its groups, its rows and the hints under it (`ChatsTab`).

/// The list's groups and their rows. Drawn again only when what they show changed: the tab around them redraws for
/// much else (a bridge that read, a contact photo, someone typing in a chat, the sidebar), and each of those went
/// through every row and built its menu again while you scrolled. The actions do the same for the same chats.
struct ChatsListRows<Menu: View>: View, Equatable {
    let sections: [ChatsSection]
    let selected: String?
    let collapsed: Set<ChatsGroup>
    let searching: Bool
    let day: Date
    /// Who types where, by chat; only the chats someone types in.
    let typing: [String: String]
    let toggle: (ChatsGroup) -> Void
    let select: (String) -> Void
    let rowAction: (ChatsEntry) -> ChatsRowAction
    let menu: (ChatsEntry) -> Menu

    static func == (a: Self, b: Self) -> Bool {
        a.selected == b.selected && a.collapsed == b.collapsed && a.searching == b.searching && a.day == b.day
            && a.typing == b.typing && a.sections == b.sections
    }

    var body: some View {
        // One flat list, not a list per group: a chat that moved to another group ("Yesterday" to "Today") was then the
        // same row in two nested lists, and the lazy stack could keep drawing its old line, its old time and no selection.
        LazyVStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(ChatsListLine.lines(sections, collapsed: collapsed, searching: searching)) { line in
                switch line {
                case .group(let section, let open):
                    ChatsGroupHeader(title: section.group.title, count: section.entries.count, open: open,
                                     first: section.group == sections.first?.group) { toggle(section.group) }
                        .disabled(searching)
                case .chat(let entry, let separated):
                    ChatsListItem(entry: entry, separated: separated, selected: entry.id == selected, day: day,
                                  typing: typing[entry.id], rowAction: rowAction(entry),
                                  select: { select(entry.id) }, menu: { menu(entry) })
                        .equatable()
                }
            }
        }
    }
}

/// One line of the Chats list: a group's title, or a chat in it. A chat's line has the chat's id, which stays the same
/// when it moves to another group, so the list moves the row (and scrolling to a chat finds it by that id).
enum ChatsListLine: Identifiable, Equatable {
    case group(ChatsSection, open: Bool)
    case chat(ChatsEntry, separated: Bool)

    var id: String {
        switch self {
        case .group(let section, _): return "group:\(section.group.rawValue)"
        case .chat(let entry, _): return entry.id
        }
    }

    /// The lines in order: each group's title, and its chats unless it is folded (a search shows every group open).
    static func lines(_ sections: [ChatsSection], collapsed: Set<ChatsGroup>, searching: Bool) -> [ChatsListLine] {
        sections.flatMap { section -> [ChatsListLine] in
            let open = searching || !collapsed.contains(section.group)
            let top = section.entries.first?.id
            return [.group(section, open: open)]
                + (open ? section.entries.map { .chat($0, separated: $0.id != top) } : [])
        }
    }
}

/// One chat in the list with the line above it and its menu, drawn again only when its row changed: when the list
/// changes (a new message moves one chat up), the other rows and their menus stay as they are.
struct ChatsListItem<Menu: View>: View, Equatable {
    let entry: ChatsEntry
    /// A line above it: every row but the first of its group.
    let separated: Bool
    let selected: Bool
    let day: Date
    let typing: String?
    let rowAction: ChatsRowAction
    let select: () -> Void
    let menu: () -> Menu

    static func == (a: Self, b: Self) -> Bool {
        a.entry == b.entry && a.separated == b.separated && a.selected == b.selected && a.day == b.day
            && a.typing == b.typing && a.rowAction.title == b.rowAction.title
    }

    var body: some View {
        // One view per chat: a lazy stack whose rows bring a separator only sometimes loses track of a row that moves
        // to the top of its group, and kept showing its old line.
        VStack(spacing: NookTheme.Spacing.xxs) {
            if separated { NookRowSeparator() }
            ChatsRow(entry: entry, selected: selected, day: day, typing: typing, rowAction: rowAction, action: select)
                .contextMenu { menu() }
        }
    }
}

/// The quiet hints at the foot of the list, together in one place: what Nook waits for, and what one click adds. It
/// watches the Contacts photos itself: when the tab did, every photo that came in drew the whole tab again.
struct ChatsListHints: View {
    let waiting: Bool
    let enabled: Bool
    let addMore: () -> Void
    @ObservedObject private var photos = ContactPhotos.shared

    var body: some View {
        if waiting || !enabled || photos.canAsk {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                if waiting {
                    // Collecting is on but no other app showed a message yet: say so, or the list looks like it ignores them.
                    Label(tr("chats.status.waiting"), systemImage: "tray")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NookTheme.Spacing.lg)
                }
                if !enabled {
                    // Only WhatsApp so far: the other chat apps are one switch away.
                    SmallGhostButton(title: tr("chats.addMore"), action: addMore)
                }
                if photos.canAsk {
                    // Photos come from Contacts on this Mac; macOS asks only after this click.
                    SmallGhostButton(title: tr("chats.photos.allow")) { photos.requestAccess() }
                }
            }
        }
    }
}
