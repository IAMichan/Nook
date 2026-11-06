import SwiftUI

/// The checks in the Summary's tab bar: their mark and "1 failing, 8 passed"; a click opens the list in a popover, what
/// needs you first and the finished ones behind "Show all". A line opens its check in the page.
struct PullRequestChecksStatus: View {
    let detail: PullRequestDetail
    let open: (PullRequestCheck) -> Void
    @State private var showing = false
    @State private var showAll = false

    private var outcome: PullRequestCheck.Outcome? {
        switch detail.checkSummary {
        case .failing: .failing
        case .pending: .pending
        case .passing: .passing
        case .unknown: nil
        }
    }

    private var summary: String {
        let counts = detail.checkCounts
        var parts: [String] = []
        if counts.failing > 0 { parts.append(tr("agents.pr.checks.failing", counts.failing)) }
        if counts.pending > 0 { parts.append(tr("agents.pr.checks.running", counts.pending)) }
        if counts.passing > 0 { parts.append(tr("agents.pr.checks.passed", counts.passing)) }
        return parts.isEmpty ? tr("agents.pr.checks.none") : parts.joined(separator: ", ")
    }

    var body: some View {
        if let outcome {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: NookTheme.Spacing.xs) {
                    CheckOutcomeGlyph(outcome: outcome)
                    Text(summary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("agents.pr.status.checks"))
            .accessibilityLabel(tr("agents.pr.status.checks") + ": " + summary)
            .popover(isPresented: $showing, arrowEdge: .bottom) { list(outcome) }
        } else {
            Text(summary)
        }
    }

    private func list(_ outcome: PullRequestCheck.Outcome) -> some View {
        let needsYou = detail.checks.filter { $0.outcome == .failing } + detail.checks.filter { $0.outcome == .pending }
        let finished = detail.checks.filter { $0.outcome == .passing } + detail.checks.filter { $0.outcome == .skipped }
        // Nothing needs you: the finished ones are all there is to show.
        let folds = !needsYou.isEmpty && !finished.isEmpty
        let shown = needsYou + (showAll || !folds ? finished : [])
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                CheckOutcomeGlyph(outcome: outcome, size: 13)
                Text(tr("agents.pulls.status." + outcome.rawValue)).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Spacer(minLength: NookTheme.Spacing.sm)
                Text(summary).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).monospacedDigit()
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            NookDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, check in
                        PullRequestHoverRow(action: {
                            showing = false
                            open(check)
                        }) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                CheckOutcomeGlyph(outcome: check.outcome, running: check.running).frame(width: 16)
                                Text(check.name).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1).help(check.name)
                                Spacer(minLength: NookTheme.Spacing.sm)
                                CICheckStatusText(check: check)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            if folds {
                NookDivider()
                HStack {
                    Spacer()
                    SmallGhostButton(title: tr(showAll ? "agents.panel.showLess" : "agents.pr.checks.showAll")) { showAll.toggle() }
                    Spacer()
                }
                .padding(NookTheme.Spacing.sm)
            }
        }
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The diff stat's hover: how the changed lines split into code, tests, mocks, generated files and docs.
struct PullRequestBreakdownCard: View {
    let breakdown: PullRequestChangeBreakdown
    let additions: Int
    let deletions: Int

    private static func title(_ kind: PullRequestChangeBreakdown.Kind) -> String { tr("agents.pr.breakdown." + kind.rawValue) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: NookTheme.Spacing.lg, verticalSpacing: NookTheme.Spacing.xs) {
            ForEach(breakdown.kinds, id: \.self) { kind in
                row(Self.title(kind), breakdown[kind])
            }
            if breakdown.kinds.count > 1 {
                NookDivider().gridCellUnsizedAxes(.horizontal)
                row(tr("agents.pr.breakdown.total"), PullRequestChangeBreakdown.Lines(additions: additions, deletions: deletions))
            }
        }
        .padding(NookTheme.Spacing.md)
        .background(DropdownStyle.panel)
    }

    private func row(_ title: String, _ lines: PullRequestChangeBreakdown.Lines) -> some View {
        GridRow {
            Text(title).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            Text("+" + lines.additions.formatted()).foregroundStyle(NookTheme.mint).gridColumnAlignment(.trailing)
            Text("−" + lines.deletions.formatted()).foregroundStyle(NookTheme.coral).gridColumnAlignment(.trailing)
        }
        .font(NookTheme.mono(11, .medium))
        .monospacedDigit()
    }
}

/// Content with a pencil beside it under the pointer, for what can be edited in place: the title, the description.
struct PullRequestEditableLine<Content: View>: View {
    let help: String
    let enabled: Bool
    let edit: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.xs) {
            content().frame(maxWidth: .infinity, alignment: .leading)
            if enabled {
                ToolbarIconButton("pencil", help, height: 20, width: 20, edit)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
        }
        .onHover { hovering = $0 }
    }
}
