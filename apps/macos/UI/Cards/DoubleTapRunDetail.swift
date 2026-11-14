import SwiftUI

/// A Double Tap's result card (`CardDetail.doubleTapRun`), where Double Tap was asked: every step Nook took, and what it
/// typed, changed or filled in, so you can check it. The card's title says how it ended.
struct DoubleTapRunDetail: View {
    let run: DoubleTapRun
    /// All steps instead of the last few.
    @State private var allSteps = false
    /// All of what Nook put in the document instead of the first few.
    @State private var allChecks = false

    /// The steps shown before "show all".
    static let recentSteps = 5
    /// What Nook put in the document, shown before "show all": the card keeps room for its buttons.
    static let firstChecks = 3

    var body: some View {
        // Long runs scroll inside the card instead of pushing its buttons out.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                if !run.steps.isEmpty { steps(run) }
                if !run.checks.isEmpty { checks(run) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("doubletap.run.title"))
        .onChange(of: run.id) { _, _ in
            allSteps = false
            allChecks = false
        }
    }

    /// How tall the card's detail wants to be for `run`, so the card asks the notch for that room.
    static func height(of run: DoubleTapRun) -> CGFloat {
        let steps = min(run.steps.count, recentSteps)
        let checks = min(run.checks.count, firstChecks)
        var height: CGFloat = 0
        if steps > 0 { height += 22 + CGFloat(steps) * 22 + (run.steps.count > recentSteps ? 20 : 0) }
        if checks > 0 { height += 22 + CGFloat(checks) * 56 + (run.checks.count + run.moreChecks > checks ? 20 : 0) }
        return height
    }

    // MARK: Steps

    private func steps(_ run: DoubleTapRun) -> some View {
        let hidden = allSteps ? 0 : max(0, run.steps.count - Self.recentSteps)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            NookSectionLabel(tr("doubletap.run.steps"), inset: 0)
            if hidden > 0 {
                Button {
                    withAnimation(NookTheme.reveal) { allSteps = true }
                } label: {
                    Text(tr("doubletap.run.earlier", hidden))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.nookPlain)
            }
            ForEach(run.steps.suffix(run.steps.count - hidden)) { step in
                HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                    mark(step.state)
                        .frame(width: 16, height: 16)
                    Text(step.text)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(step.state == .running ? NookTheme.textStrong : NookTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(tr(Self.stateKey(step.state), step.text))
            }
        }
    }

    @ViewBuilder
    private func mark(_ state: DoubleTapRun.StepState) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .done:
            Image(icon: "checkmark")
                .font(NookTheme.font(10, .bold))
                .foregroundStyle(NookTheme.textTertiary)
        case .failed:
            Image(icon: "xmark")
                .font(NookTheme.font(10, .bold))
                .foregroundStyle(NookTheme.coral)
        }
    }

    private static func stateKey(_ state: DoubleTapRun.StepState) -> String {
        switch state {
        case .running: return "doubletap.run.a11y.running"
        case .done: return "doubletap.run.a11y.done"
        case .failed: return "doubletap.run.a11y.failed"
        }
    }

    // MARK: What to check

    /// What Nook put in the document, in full and selectable, so you can read it over before you send anything.
    private func checks(_ run: DoubleTapRun) -> some View {
        let shown = allChecks ? run.checks : Array(run.checks.prefix(Self.firstChecks))
        let hidden = run.checks.count - shown.count
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            NookSectionLabel(tr("doubletap.run.checks"), inset: 0)
            ForEach(shown) { check in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if !check.label.isEmpty {
                        Text(check.label)
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Text(check.value)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.textStrong)
                        .lineLimit(allChecks ? 12 : 5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .help(check.value)
                }
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.vertical, NookTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard()
            }
            if hidden > 0 {
                Button {
                    withAnimation(NookTheme.reveal) { allChecks = true }
                } label: {
                    Text(tr("doubletap.card.more", hidden + run.moreChecks))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.nookPlain)
            } else if run.moreChecks > 0 {
                Text(tr("doubletap.card.more", run.moreChecks))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }
}
