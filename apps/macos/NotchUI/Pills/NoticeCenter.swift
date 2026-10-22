import SwiftUI

/// The bell in the panel's header: what Nook told you lately (an agent that finished, a request, a message), so a card
/// that closed before you looked can still be read. A dot on the bell while there is something you have not seen; a click
/// on an entry opens what it is about.
struct NoticeBellButton: View {
    @ObservedObject private var history = NoticeHistory.shared
    @EnvironmentObject private var app: AppModel
    @State private var open = false

    var body: some View {
        let unseen = history.unseen
        let label = unseen > 0 ? tr("notices.new", unseen) : tr("notices.title")
        NookIconButton(systemName: "bell", label: label, size: 30) { open.toggle() }
            .overlay(alignment: .topTrailing) {
                if unseen > 0 {
                    Circle()
                        .fill(NookTheme.iris)
                        .frame(width: 7, height: 7)
                        .padding(NookTheme.Spacing.sm)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(NookTheme.hover, value: unseen > 0)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                NoticeCenterList(history: history) { entry in
                    open = false
                    app.openNotice(entry)
                }
                // What was on screen has been seen once the list closes; while open, the new ones keep their dot.
                .onDisappear { history.markAllSeen() }
            }
    }
}

/// The list under the bell, newest first.
struct NoticeCenterList: View {
    @ObservedObject var history: NoticeHistory
    let open: (NoticeEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("notices.title"))
                    .font(NookTheme.TextStyle.title)
                    .foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.sm)
                if !history.entries.isEmpty {
                    ConfirmedButton(tr("notices.clear"), question: tr("notices.clear.question"),
                                    detail: tr("notices.clear.detail")) { history.clear() }
                        .buttonStyle(.plain)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.top, NookTheme.Spacing.lg)
            .padding(.bottom, NookTheme.Spacing.sm)

            if history.entries.isEmpty {
                ListEmptyNote(tr("notices.empty"))
                    .padding(.horizontal, NookTheme.Spacing.lg)
                    .padding(.bottom, NookTheme.Spacing.lg)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(history.entries) { entry in
                            NoticeRow(entry: entry) { open(entry) }
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

/// One notice: its state as a tinted mark, what happened, the detail it came with, and who, where and when.
struct NoticeRow: View {
    let entry: NoticeEntry
    let open: () -> Void
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
                        .foregroundStyle(NookTheme.paper)
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
                if !entry.seen {
                    Circle()
                        .fill(NookTheme.iris)
                        .frame(width: 6, height: 6)
                        .padding(.top, NookTheme.Spacing.sm)
                        .accessibilityLabel(tr("notices.unseen"))
                }
            }
            .padding(NookTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .fill(NookTheme.rowFill(selected: false, hovering: hovering && opens))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!opens)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
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
