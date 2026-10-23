import SwiftUI

/// A pull request open on the Pull requests page, with the account it is read with.
struct OpenPullRequest: Identifiable, Equatable {
    let account: String
    var item: PullRequestItem
    var id: String { account + " " + item.id }
}

/// The pull requests you opened, as tabs above the one you read: each with its state mark, number and title, and a
/// close button on the open tab or under the pointer. The right-click menu closes it, the others, the ones to its
/// right, or all of them.
struct PullRequestTabStrip: View {
    let tabs: [OpenPullRequest]
    let active: String?
    let select: (String) -> Void
    let close: (Set<String>) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    ForEach(tabs) { tab in
                        PullRequestTab(tab: tab, active: tab.id == active, select: { select(tab.id) },
                                       close: { close([tab.id]) })
                            .id(tab.id)
                            .contextMenu { menu(for: tab) }
                    }
                }
            }
            .onChange(of: active) { _, id in
                if let id { withAnimation(NookTheme.scroll) { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private func menu(for tab: OpenPullRequest) -> some View {
        let index = tabs.firstIndex(of: tab) ?? 0
        Button(tr("agents.pulls.tabs.close")) { close([tab.id]) }
        Button(tr("agents.pulls.tabs.closeOthers")) { close(Set(tabs.map(\.id)).subtracting([tab.id])) }
            .disabled(tabs.count < 2)
        Button(tr("agents.pulls.tabs.closeRight")) { close(Set(tabs[(index + 1)...].map(\.id))) }
            .disabled(index >= tabs.count - 1)
        Divider()
        Button(tr("agents.pulls.tabs.closeAll")) { close(Set(tabs.map(\.id))) }
    }
}

private struct PullRequestTab: View {
    let tab: OpenPullRequest
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Button(action: select) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    PullRequestStateGlyph(glyph: glyph, size: 12, lineWidth: 1.5, nodeRadius: 1.8)
                        .foregroundStyle(tint)
                        .frame(width: 12, height: 12)
                    Text("#\(tab.item.number)").font(NookTheme.mono(11, .medium)).monospacedDigit()
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(tab.item.title.isEmpty ? tab.item.repo : tab.item.title)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.item.repo + " #\(tab.item.number)")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(NookTheme.font(8.5, .bold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(active || hovering ? 1 : 0)
            .help(tr("agents.pulls.tabs.close"))
            .accessibilityLabel(tr("agents.pulls.tabs.close"))
        }
        .padding(.leading, NookTheme.Spacing.sm)
        .padding(.trailing, NookTheme.Spacing.xs)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
            .fill(NookTheme.rowFill(selected: active, hovering: hovering, rest: .clear)))
        .onHover { hovering = $0 }
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var glyph: PullRequestBadge.Glyph {
        switch tab.item.state {
        case .merged: return .merged
        case .closed: return .closed
        case .open: return tab.item.draft ? .draft : .open
        }
    }

    private var tint: Color {
        switch tab.item.state {
        case .merged: return NookTheme.violet
        case .closed: return NookTheme.coralSoft
        case .open: return tab.item.draft ? NookTheme.textTertiary : NookTheme.mint
        }
    }
}
