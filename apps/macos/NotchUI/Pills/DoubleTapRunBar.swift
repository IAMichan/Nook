import SwiftUI

/// A Double Tap in the open notch, under the tabs: the step Nook is on and every step before it, and once it is done
/// the result and what it typed, changed or filled in, so you can check it. Stop while it works, Close once it is done;
/// a finished run also leaves by itself after `DoubleTap.keepRun`.
struct DoubleTapRunBar: View {
    @ObservedObject var doubleTap: DoubleTap
    /// All steps instead of the last few.
    @State private var allSteps = false
    /// All of what Nook put in the document instead of the first few.
    @State private var allChecks = false

    /// The steps shown before "show all".
    static let recentSteps = 5
    /// What Nook put in the document, shown before "show all": the notch keeps room for the tab under it.
    static let firstChecks = 3

    var body: some View {
        if let run = doubleTap.run {
            content(run)
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.md)
                .cardBackground(NookTheme.surface, stroke: NookTheme.line2, radius: NookTheme.Radius.panel, style: .continuous)
                .padding(.top, NookTheme.Spacing.md)
                .transition(.opacity.combined(with: .offset(y: -4)))
                .animation(NookTheme.reveal, value: run)
                // The notch closed while Nook works: its step goes on under the notch (never over what opened since).
                .onDisappear { Task { @MainActor in doubleTap.showStepAgain() } }
                .onChange(of: run.id) { _, _ in
                    allSteps = false
                    allChecks = false
                }
        }
    }

    private func content(_ run: DoubleTapRun) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            NookNotice(title: title(run), detail: subtitle(run), symbol: symbol(run), tone: tone(run),
                       actions: [action(run)], wraps: true)
            if !run.steps.isEmpty { steps(run) }
            if !run.checks.isEmpty { checks(run) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("doubletap.run.title"))
    }

    // MARK: Header

    /// Stop while Nook works, Close once it is done.
    private func action(_ run: DoubleTapRun) -> NookNoticeAction {
        if run.isRunning { return NookNoticeAction(tr("takeover.stop")) { doubleTap.stop() } }
        return NookNoticeAction(tr("button.close")) {
            withAnimation(NookTheme.close) { doubleTap.dismissRun() }
        }
    }

    private func title(_ run: DoubleTapRun) -> String {
        if !run.isRunning { return run.result.isEmpty ? tr("doubletap.run.ended") : run.result }
        return run.steps.last?.text ?? tr("doubletap.run.starting")
    }

    /// Double Tap · the app · what you asked; once done also how long it took and the result's own line.
    private func subtitle(_ run: DoubleTapRun) -> String {
        var parts = [tr("doubletap.settings.title")]
        if !run.app.isEmpty { parts.append(run.app) }
        if !run.request.isEmpty { parts.append("“" + DoubleTapLogic.preview(run.request) + "”") }
        if let seconds = run.seconds { parts.append(tr("doubletap.run.seconds", seconds)) }
        let line = parts.joined(separator: " · ")
        return run.resultDetail.isEmpty ? line : line + "\n" + run.resultDetail
    }

    private func symbol(_ run: DoubleTapRun) -> String {
        switch run.outcome {
        case nil: return "hand.tap.fill"
        case .done: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    private func tone(_ run: DoubleTapRun) -> Color {
        switch run.outcome {
        case nil, .info: return NookTheme.iris
        case .done: return NookTheme.mint
        case .failed: return NookTheme.amber
        case .stopped: return NookTheme.textSecondary
        }
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
                .buttonStyle(.plain)
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
            Image(systemName: "checkmark")
                .font(NookTheme.font(10, .bold))
                .foregroundStyle(NookTheme.textTertiary)
        case .failed:
            Image(systemName: "xmark")
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
                .buttonStyle(.plain)
            } else if run.moreChecks > 0 {
                Text(tr("doubletap.card.more", run.moreChecks))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
    }
}
