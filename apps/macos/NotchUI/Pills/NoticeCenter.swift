import SwiftUI

/// The bell in the panel's header: what Nook told you lately (an agent that finished, a request, a message), so a card
/// that closed before you looked can still be read. While there is something you have not seen, the bell
/// carries how many; while its list is open, it is lit. A click on an entry opens what it is about.
struct NoticeBellButton: View {
    @ObservedObject private var history = NoticeHistory.shared
    @EnvironmentObject private var app: AppModel
    @State private var open = false

    var body: some View {
        let unseen = history.unseen
        let label = unseen > 0 ? tr("notices.new", unseen) : tr("notices.title")
        NookIconButton(systemName: symbol(unseen: unseen), label: label, size: 30) { open.toggle() }
            .overlay(alignment: .topTrailing) {
                if unseen > 0 {
                    NoticeBellCount(count: unseen)
                        .offset(x: NookTheme.Spacing.xxs, y: -NookTheme.Spacing.xxs)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(NookTheme.hover, value: unseen > 0)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                NoticeCenterList(history: history, open: { entry in
                    history.markSeen(entry)
                    guard entry.target != .nowhere else { return }
                    open = false
                    app.openNotice(entry)
                }, openSettings: {
                    open = false
                    app.openSettings(section: .notifications)
                })
                // What was on screen has been seen once the list closes; while open, the new ones keep their dot.
                .onDisappear { history.markAllSeen() }
            }
    }

    /// Lit while its list is open; the count on its corner tells what waits.
    private func symbol(unseen: Int) -> String {
        if open { return "bell.fill" }
        return "bell"
    }
}

/// How many notices you have not seen, on the bell's corner: the accent with its number, "9+" past nine.
private struct NoticeBellCount: View {
    let count: Int

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(NookTheme.rounded(9, .bold))
            .foregroundStyle(NookTheme.onIris)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(NookTheme.iris))
            .overlay(Capsule().strokeBorder(NookTheme.graphite, lineWidth: 1.5))
    }
}

/// The list under the bell, newest first: mark everything read, clear it, or go to what may notify you.
struct NoticeCenterList: View {
    @ObservedObject var history: NoticeHistory
    let open: (NoticeEntry) -> Void
    var openSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The same title row as every list in the panel.
            PanelListHeader(tr("notices.title"), count: history.unseen) {
                if history.unseen > 0 {
                    ToolbarIconButton("checkmark.circle", tr("notices.markRead")) { history.markAllSeen() }
                }
                if !history.entries.isEmpty {
                    ConfirmedButton(tr("notices.clear"), question: tr("notices.clear.question"),
                                    detail: tr("notices.clear.detail")) { history.clear() }
                        .buttonStyle(.plain)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                        .padding(.horizontal, NookTheme.Spacing.xs)
                }
                ToolbarIconButton("gearshape", tr("notices.settings.open"), openSettings)
            }
            .padding(.trailing, NookTheme.Spacing.lg)
            .padding(.top, NookTheme.Spacing.md)
            .padding(.bottom, NookTheme.Spacing.sm)

            if history.entries.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    ListEmptyNote(tr("notices.empty"))
                    Button(tr("notices.settings.choose"), action: openSettings)
                        .buttonStyle(.plain)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.blue)
                }
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.bottom, NookTheme.Spacing.lg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(history.entries) { entry in
                            NoticeRow(entry: entry, open: { open(entry) }, remove: { history.remove(entry) })
                        }
                    }
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.bottom, NookTheme.Spacing.sm)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 360)
        .background(NookTheme.surface)
    }
}

/// One notice: its state as a tinted mark, what happened, the detail it came with, and who, where and when. Under the
/// pointer it shows where a click takes you (a chevron, only when it opens something) and a cross that removes it.
struct NoticeRow: View {
    let entry: NoticeEntry
    let open: () -> Void
    var remove: () -> Void = {}
    @State private var hovering = false

    private var opens: Bool { entry.target != .nowhere }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                Image(systemName: entry.kind.symbol)
                    .font(NookTheme.font(10, .bold))
                    .foregroundStyle(entry.kind.color)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(entry.kind.color.opacity(0.16)))
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(entry.title)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(entry.seen ? NookTheme.textSecondary : NookTheme.paper)
                        .lineLimit(2)
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(3)
                    }
                    Text(meta)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The end of the row: the cross and where it leads under the pointer, the dot of a new one otherwise.
                HStack(spacing: NookTheme.Spacing.xxs) {
                    if hovering {
                        ToolbarIconButton("xmark", tr("notices.remove"), height: 20, width: 20, remove)
                        if opens {
                            Image(systemName: "chevron.right")
                                .font(NookTheme.font(10, .semibold))
                                .foregroundStyle(NookTheme.textTertiary)
                                .frame(width: 12, height: 20)
                        }
                    } else if !entry.seen {
                        Circle()
                            .fill(NookTheme.iris)
                            .frame(width: 6, height: 6)
                            .frame(height: 20)
                            .accessibilityLabel(tr("notices.unseen"))
                    }
                }
                .frame(minWidth: 20, alignment: .trailing)
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.md)
            // Rows sit on the popover's own surface and only light up under the pointer.
            .background(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .fill(NookTheme.rowFill(selected: false, hovering: hovering, rest: .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(opens ? tr("notices.openHint") : "")
    }

    /// "Claude Code · nook · 12 min ago"
    private var meta: String {
        [entry.context, NookDates.ago(entry.date)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension NoticeEntry.Kind {
    /// The mark the confirmation strip shows for the same state; a plain notice gets Nook's bell.
    var symbol: String {
        switch self {
        case .done: return DoneTone.done.symbol
        case .failed: return DoneTone.failed.symbol
        case .waiting: return DoneTone.waiting.symbol
        case .info: return "bell.fill"
        }
    }

    var color: Color {
        switch self {
        case .done: return DoneTone.done.color
        case .failed: return DoneTone.failed.color
        case .waiting: return DoneTone.waiting.color
        case .info: return NookTheme.iris
        }
    }
}
