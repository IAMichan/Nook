import SwiftUI

// The small pieces the pull request page is drawn with (see PullRequestDetailView and its tabs).

/// A part of the Summary under a heading that folds it: the name and a chevron on the left,
/// what the part offers (a count, a filter, the order) on the right.
struct PullRequestSummarySection<Content: View, Accessory: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, open: Binding<Bool>, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        _open = open
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Button {
                    withAnimation(NookTheme.reveal) { open.toggle() }
                } label: {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text(title).font(NookTheme.TextStyle.label)
                        Image(systemName: "chevron.right")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(NookTheme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? tr("compose.queue.expanded") : "")
                Spacer(minLength: NookTheme.Spacing.sm)
                accessory().foregroundStyle(NookTheme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            if open { content() }
        }
    }
}

/// A place on a tab's page to scroll to; each request is new, so asking for the same place twice still scrolls.
struct PullRequestPageScrollRequest: Equatable {
    static let checks = "pr.summary.checks"
    let target: String
    let token = UUID()
}

/// Where a tab's page is scrolled, and how much taller its content is than the room it has.
struct PullRequestPageScroll: Equatable {
    let offset: CGFloat
    let overflow: CGFloat
}

/// One entry on the timeline: its marker on a thin rail that runs down to the next entry, the entry beside it.
struct PullRequestTimelineRail<Marker: View, Content: View>: View {
    let last: Bool
    @ViewBuilder let marker: () -> Marker
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.xl + NookTheme.Spacing.xs) {
            marker().frame(width: 28, height: 28)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, NookTheme.Spacing.xl + NookTheme.Spacing.xs)
        .background(alignment: .topLeading) {
            if !last {
                NookDivider(vertical: true)
                    .padding(.leading, 13.5)
                    .padding(.top, 30)
            }
        }
    }
}

/// The round marker of an event on the timeline rail.
struct PullRequestTimelineMarker: View {
    let symbol: String
    let color: Color

    var body: some View {
        NookSymbol(symbol, size: 12)
            .font(NookTheme.font(10.5, .medium))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(Circle().fill(NookTheme.notch))
    }
}

/// One commit on the timeline: the subject in bold (lit under the pointer; a click opens it on GitHub), the short hash and
/// when under it. A commit with more to say than its subject gets a quiet "…" that unfolds the rest of its message.
struct PullRequestCommitEntry: View {
    let sha: String
    let message: String
    /// The message under the subject; empty for a one-line commit.
    var details = ""
    let time: String?
    let date: Date?
    let open: () -> Void
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Button(action: open) {
                    Text(message.isEmpty ? tr("agents.pr.timeline.pushedOne") : message)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(hovering ? NookTheme.iris : NookTheme.paper)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                if !details.isEmpty {
                    Button {
                        withAnimation(NookTheme.reveal) { expanded.toggle() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(NookTheme.font(9, .bold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .frame(width: 20, height: 14)
                            .background(Capsule().fill(expanded ? NookTheme.rowSelected : NookTheme.rowHover))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tr("agents.pr.timeline.commitDetails"))
                    .accessibilityLabel(tr("agents.pr.timeline.commitDetails"))
                    .accessibilityValue(expanded ? tr("compose.queue.expanded") : "")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(String(sha.prefix(7))).font(NookTheme.mono(10.5))
                if let time { Text(time).font(NookTheme.font(10.5)).monospacedDigit() }
            }
            .foregroundStyle(NookTheme.textTertiary)
            if expanded {
                Text(details)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, NookTheme.Spacing.xxs)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Five small blocks, like GitHub's: green for the share of added lines, red for removed ones.
struct PullRequestDiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = additions + deletions
        let green = total == 0 ? 0 : Int((Double(additions) / Double(total) * 5).rounded())
        let red = total == 0 ? 0 : 5 - green
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < green ? NookTheme.mint : index < green + red ? NookTheme.coral : NookTheme.line2)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A full-width row that lights up under the pointer.
struct PullRequestHoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? NookTheme.rowHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Loading placeholders

/// A grey bar where text will be.
struct PullRequestGhostBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
            .fill(NookTheme.rowHover)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A row-shaped placeholder: a dot and two lines.
struct PullRequestGhostRow: View {
    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Circle().fill(NookTheme.rowHover).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                PullRequestGhostBar(height: 9)
                PullRequestGhostBar(width: 120, height: 7)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
    }
}

/// The page's shape while the first answer is on its way: the tabs, the overview card and the description.
struct PullRequestDetailGhost: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ForEach(Array([80, 90, 80, 70, 64].enumerated()), id: \.offset) { _, width in
                    PullRequestGhostBar(width: CGFloat(width), height: 22)
                }
            }
            VStack(spacing: 0) {
                PullRequestGhostRow()
                PullRequestGhostRow()
            }
            .panelCard()
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                PullRequestGhostBar()
                PullRequestGhostBar()
                PullRequestGhostBar(width: 180)
            }
            .padding(NookTheme.Spacing.lg)
            .panelCard()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("agents.pr.loading"))
    }
}

extension View {
    /// The pull request page's one column: the full width up to `PullRequestDetailView.pageWidth`, centered on a wider
    /// window. `alignment` places the content inside it (`.trailing` for the write button in its corner).
    func pullRequestPageColumn(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: PullRequestDetailView.pageWidth, alignment: alignment)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
