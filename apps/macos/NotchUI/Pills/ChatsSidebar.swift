import SwiftUI

/// What the Chats list shows, by where a chat stands. The same four views for every chat app: WhatsApp, Instagram,
/// Telegram and the others are read the same way (see `ChatReadState`).
enum ChatsView: String, CaseIterable, Identifiable {
    /// Every chat.
    case all
    /// Something new to read.
    case unread
    /// Read in Nook, still unread in the chat's own app: what you may want to pass on.
    case readInNook
    /// Read everywhere.
    case read

    var id: String { rawValue }
    var title: String { tr("chats.view." + rawValue) }

    func shows(_ state: ChatReadState) -> Bool {
        switch self {
        case .all: return true
        case .unread: return state.isUnread
        case .readInNook: return state == .readInNook
        case .read: return state == .read
        }
    }

    /// Only the views where a waiting count helps get one: what is new, and what is read in Nook only.
    var counts: Bool { self == .unread || self == .readInNook }
}

/// Where a chat stands, as a small mark at the end of its row and in its read line: the count of what is new, one grey
/// tick for read in Nook, two mint ticks for read in the app too. The same marks the sidebar's views and legend use.
struct ChatReadMark: View {
    let state: ChatReadState

    var body: some View {
        switch state {
        case .unread(let count):
            NookCountBadge(count: count)
        case .readInNook:
            ChatTicks(count: 1, tint: NookTheme.textTertiary)
                .help(tr("chats.legend.readInNook"))
                .accessibilityLabel(tr("chats.legend.readInNook"))
        case .read:
            ChatTicks(count: 2, tint: NookTheme.mint)
                .help(tr("chats.legend.read"))
                .accessibilityLabel(tr("chats.legend.read"))
        }
    }
}

/// One or two ticks, drawn close together as a chat app draws them.
struct ChatTicks: View {
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: -NookTheme.Spacing.xs - 1) {
            ForEach(0..<count, id: \.self) { _ in
                Image(systemName: "checkmark")
            }
        }
        .font(NookTheme.font(9.5, .bold))
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// The Chats tab's sidebar: the views by where a chat stands, then every app with chats here (or switched on), then a
/// way to add one, and at the foot what the marks mean. Folded to a rail of icons when the panel is narrow.
struct ChatsSidebar: View {
    let compact: Bool
    @Binding var view: ChatsView
    /// The app the list shows only (its source id), or nil for every app.
    @Binding var app: String?
    /// How many chats each view lists, within the chosen app.
    let counts: [ChatsView: Int]
    /// The apps to offer, busiest and newest first.
    let apps: [String]
    /// Chats with something new per app.
    let newByApp: [String: Int]
    let addSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    ForEach(ChatsView.allCases) { item in
                        ChatsSidebarRow(title: item.title, count: item.counts ? counts[item] ?? 0 : 0,
                                        countTint: item == .unread ? NookTheme.amber : NookTheme.textTertiary,
                                        selected: view == item, compact: compact) {
                            ChatsViewGlyph(view: item)
                        } action: {
                            withAnimation(NookTheme.swap) { view = item }
                        }
                    }
                    if !apps.isEmpty {
                        if compact {
                            NookDivider()
                                .padding(.vertical, NookTheme.Spacing.sm)
                        } else {
                            NookSectionLabel(tr("chats.sidebar.apps"), inset: NookTheme.Spacing.md)
                                .padding(.top, NookTheme.Spacing.lg)
                                .padding(.bottom, NookTheme.Spacing.xs)
                        }
                        ForEach(apps, id: \.self) { id in
                            ChatsSidebarRow(title: MessagingApps.app(id: id)?.name ?? id, count: newByApp[id] ?? 0,
                                            countTint: NookTheme.amber, selected: app == id, compact: compact) {
                                SiteIcon(domain: nil, fallback: "bubble.left.fill", tint: NookTheme.textSecondary, size: 15,
                                         source: id)
                            } action: {
                                withAnimation(NookTheme.swap) { app = app == id ? nil : id }
                            }
                        }
                    }
                    ChatsSidebarRow(title: tr("chats.addSource"), count: 0, countTint: NookTheme.textTertiary,
                                    selected: false, compact: compact, muted: true) {
                        Image(systemName: "plus")
                            .font(NookTheme.font(11, .semibold))
                    } action: {
                        addSource()
                    }
                    .padding(.top, NookTheme.Spacing.xxs)
                }
                .padding(.horizontal, compact ? NookTheme.Spacing.xs : NookTheme.Spacing.sm)
                .padding(.vertical, NookTheme.Spacing.xs)
            }
            if !compact {
                legend
            }
        }
        .frame(width: compact ? PanelLayout.chatsRail : PanelLayout.chatsSidebar)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// What the marks in the list mean, said once, quietly, at the foot.
    private var legend: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            NookDivider()
                .padding(.bottom, NookTheme.Spacing.xs)
            legendLine(.unread(1), tr("chats.legend.unread"))
            legendLine(.readInNook, tr("chats.legend.readInNook"))
            legendLine(.read, tr("chats.legend.read"))
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.bottom, NookTheme.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private func legendLine(_ state: ChatReadState, _ text: String) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Group {
                if state.isUnread {
                    Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
                } else {
                    ChatTicks(count: state == .read ? 2 : 1, tint: state == .read ? NookTheme.mint : NookTheme.textTertiary)
                }
            }
            .frame(width: 18)
            Text(text)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
        }
    }
}

/// A view's own mark in the sidebar: the marks the list uses for the same state.
private struct ChatsViewGlyph: View {
    let view: ChatsView

    var body: some View {
        switch view {
        case .all:
            Image(systemName: "tray.full")
                .font(NookTheme.font(11.5, .medium))
        case .unread:
            Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .readInNook:
            ChatTicks(count: 1, tint: NookTheme.textSecondary)
        case .read:
            ChatTicks(count: 2, tint: NookTheme.mint)
        }
    }
}

/// One line of the sidebar: its mark, its name and how many wait there; in the rail only the mark, with a dot when
/// something waits and the name on hover.
private struct ChatsSidebarRow<Glyph: View>: View {
    let title: String
    let count: Int
    let countTint: Color
    let selected: Bool
    let compact: Bool
    var muted = false
    let glyph: () -> Glyph
    let action: () -> Void
    @State private var hovering = false

    init(title: String, count: Int, countTint: Color, selected: Bool, compact: Bool, muted: Bool = false,
         @ViewBuilder glyph: @escaping () -> Glyph, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.countTint = countTint
        self.selected = selected
        self.compact = compact
        self.muted = muted
        self.glyph = glyph
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.md) {
                glyph()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(muted ? NookTheme.textTertiary : NookTheme.textSecondary)
                    .overlay(alignment: .topTrailing) {
                        if compact, count > 0 {
                            Circle().fill(countTint).frame(width: 5, height: 5).offset(x: 3, y: -2)
                        }
                    }
                if !compact {
                    Text(title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(selected ? NookTheme.paper : (muted ? NookTheme.textTertiary : NookTheme.textStrong))
                        .lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    if count > 0 {
                        Text("\(count)")
                            .font(NookTheme.rounded(11, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(countTint)
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: compact ? .center : .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(count > 0 ? "\(title): \(count)" : title)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Under an open chat, above its answer field: where it stands and the one step that is left. Something new can be read
/// in Nook; read in Nook, it can be passed on to the app ("Mark as read in Telegram"), which Nook tells itself where it
/// can, and otherwise opens the app so you read it there. Read everywhere, it says so and asks nothing.
struct ChatReadLine: View {
    let state: ChatReadState
    let appName: String
    let handoff: ChatReadHandoff
    let markReadInNook: () -> Void
    let markReadInApp: () -> Void

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            ChatReadMark(state: state)
                .frame(minWidth: 16)
            Text(line)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(explanation)
            Spacer(minLength: NookTheme.Spacing.sm)
            if state.isUnread {
                SmallGhostButton(title: tr("chats.markReadInNook"), action: markReadInNook)
                    .fixedSize()
            }
            if state != .read {
                ChatPassOnButton(title: tr("chats.markReadInApp", appName), help: explanation, action: markReadInApp)
            }
        }
        .animation(NookTheme.reveal, value: state)
    }

    private var line: String {
        switch state {
        case .unread(let count): return tr("chats.status.unread", count)
        case .readInNook: return tr("chats.status.readInNook", appName)
        case .read: return tr("chats.status.read", appName)
        }
    }

    /// What passing it on does for this app.
    private var explanation: String {
        switch handoff {
        case .tells: return tr("chats.status.tells", appName)
        case .opensApp: return tr("chats.status.opensApp", appName)
        }
    }
}

/// "Mark as read in <app>": a quiet outlined capsule with the two ticks it gives the chat.
private struct ChatPassOnButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ChatTicks(count: 2, tint: NookTheme.mint)
                Text(title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .overlay(Capsule().strokeBorder(NookTheme.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .fixedSize()
        .help(help)
        .accessibilityHint(help)
    }
}
