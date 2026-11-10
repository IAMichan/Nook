import SwiftUI

/// A pull request open on the Pull requests page, with the account it is read with.
struct OpenPullRequest: Identifiable, Equatable {
    let account: String
    var item: PullRequestItem
    var id: String { account + " " + item.id }
}

/// The pull requests you opened, as tabs above the one you read: each its state mark and
/// number (the title in its tooltip), the mark turning into a close button under the pointer. The right-click menu
/// closes it, the others, the ones to its right, or all of them.
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
        .frame(height: 28)
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
        HStack(spacing: NookTheme.Spacing.xxs) {
            // The state's mark, which turns into the close button under the pointer.
            Button(action: close) {
                Group {
                    if hovering {
                        Image(icon: "xmark").font(NookTheme.font(8.5, .bold)).foregroundStyle(NookTheme.textSecondary)
                    } else {
                        PullRequestStateIcon(glyph: tab.item.stateGlyph)
                    }
                }
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("agents.pulls.tabs.close"))
            .accessibilityLabel(tr("agents.pulls.tabs.close"))
            Button(action: select) {
                Text("#\(tab.item.number)")
                    .font(NookTheme.font(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(active || hovering ? NookTheme.paper : NookTheme.textTertiary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, NookTheme.Spacing.xs)
        .padding(.trailing, NookTheme.Spacing.md)
        .frame(height: 24)
        .frame(maxWidth: 144)
        .roundedBackground(NookTheme.rowFill(selected: active, hovering: hovering, rest: .clear), radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.item.repo + " #\(tab.item.number)" + (tab.item.title.isEmpty ? "" : " · " + tab.item.title))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
