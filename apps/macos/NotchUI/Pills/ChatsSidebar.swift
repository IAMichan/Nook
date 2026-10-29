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

/// Under an open chat with something new, in the tray above its answer field: how much is new and the steps left. It can be
/// read in Nook, or passed on to the app at once ("Mark as read in Telegram"), which Nook tells itself where it can, and
/// otherwise opens the app so you read it there. Once read, the tray goes and `ChatReadStatus` in the header says where it stands.
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
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(explanation)
            Spacer(minLength: NookTheme.Spacing.sm)
            if state.isUnread {
                ChatMarkButton(to: .readInNook, title: tr("chats.markReadInNook"), help: tr("chats.legend.readInNook"),
                               action: markReadInNook)
            }
            if state != .read {
                ChatMarkButton(to: .read, title: tr("chats.markReadInApp", appName), help: explanation, action: markReadInApp)
            }
        }
        // The same row as the queued messages' header in an agent's tray (see `QueuedMessagesStrip`).
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, 3)
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

/// In an open chat's header, after the app's name: where a chat that is no longer new stands, kept as quiet as the
/// rest of that line. Read in Nook it shows one tick and its word, and a click passes it on to the app (the "…" menu
/// holds the same step); read everywhere it is just the two mint ticks.
struct ChatReadStatus: View {
    let state: ChatReadState
    let appName: String
    let handoff: ChatReadHandoff
    let markReadInApp: () -> Void
    @State private var hovering = false

    var body: some View {
        switch state {
        case .unread:
            EmptyView()
        case .readInNook:
            Button(action: markReadInApp) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    ChatTicks(count: 1, tint: hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                    Text(tr("chats.legend.readInNook"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(hovering ? NookTheme.textSecondary : NookTheme.textTertiary)
                        .underline(hovering)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .help("\(tr("chats.markReadInApp", appName)): \(explanation)")
            .accessibilityLabel(tr("chats.markReadInApp", appName))
        case .read:
            ChatTicks(count: 2, tint: NookTheme.mint)
                .help(tr("chats.status.read", appName))
                .accessibilityLabel(tr("chats.status.read", appName))
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

/// A step that moves a chat to another read state ("Read in Nook", "Mark as read in <app>", "Mark as unread"): an
/// outlined capsule with the mark the chat gets (one tick, two mint ticks, the amber dot of something new) and its word,
/// so what a click does is plain before it is made. `compact` is the size a chat's row shows under the pointer.
struct ChatMarkButton: View {
    /// Where the chat stands after the click.
    let to: ChatReadState
    let title: String
    let help: String
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? NookTheme.Spacing.xs : NookTheme.Spacing.sm) {
                mark
                Text(title)
                    .font(compact ? NookTheme.TextStyle.caption : NookTheme.TextStyle.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, compact ? NookTheme.Spacing.md : NookTheme.Spacing.lg)
            .frame(height: compact ? 22 : 26)
            .background(Capsule().fill(hovering ? NookTheme.smoke : (compact ? NookTheme.surface : Color.clear)))
            .overlay(Capsule().strokeBorder(NookTheme.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var mark: some View {
        switch to {
        case .unread:
            Circle()
                .fill(NookTheme.amber)
                .frame(width: 7, height: 7)
        case .readInNook:
            ChatTicks(count: 1, tint: NookTheme.textSecondary)
        case .read:
            ChatTicks(count: 2, tint: NookTheme.mint)
        }
    }
}

/// In the tray above the answer field of a chat Nook can only read, the same for every app: what is missing here and
/// the one step that brings it. An app Nook can link (WhatsApp, Telegram, Instagram, Slack, Teams…) gets a button to
/// Settings › Chats; one it can only see through notifications says so and opens the app. A cross puts it away for
/// that app.
struct ChatLimitsLine: View {
    let appName: String
    /// Nook can link this app fully (through its chat helper or a bridge of its own).
    let linkable: Bool
    let link: () -> Void
    let openApp: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "eye")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.amber)
                .frame(minWidth: 16)
                .accessibilityHidden(true)
            Text(tr(linkable ? "chats.limits.linkable" : "chats.limits.notifications", appName))
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: NookTheme.Spacing.sm)
            if linkable {
                SmallGhostButton(title: tr("chats.limits.link", appName), action: link)
            } else {
                SmallGhostButton(title: tr("chats.openApp", appName), action: openApp)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("chats.limits.hide"))
            .accessibilityLabel(tr("chats.limits.hide"))
        }
        // The same row as the read line and the queued messages' header (see `ChatReadLine`).
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, 3)
    }
}
