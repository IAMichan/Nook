import SwiftUI

/// Over a browser's page while an agent drives it (`BrowserStore.drivenBy`): the page's edges glow and breathe in Nook's
/// own color, and a pill at the bottom names the agent with a Stop button. Stopping halts the page and refuses the
/// agent's next step until you allow agents again, which the same pill offers. Every place that shows a browser's page
/// (the side panel, the browser page, the popup window, the corner of a chat) lays this over its web view.
///
/// The glow runs in the render server (`LayerLoop`), so the main thread draws nothing per frame while it breathes, and it
/// takes no clicks: you can keep using the page under it.
struct BrowserTakeoverOverlay: View {
    @ObservedObject var store: BrowserStore
    /// A small place (the corner of a chat): a shorter pill.
    var compact = false

    @ObservedObject private var energy = EnergyMonitor.shared
    @Environment(\.nookAttended) private var attended
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if store.drivenBy != nil {
                LayerLoop(shape: .edgeGlow(thickness: compact ? 18 : 34, low: 0.35, high: 1, period: 2.4),
                          color: NookTheme.iris,
                          fps: reduceMotion ? 0 : energy.plan.progressFrameRate(attended: attended))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
            if let agent = store.drivenBy {
                drivingPill(agent)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if store.agentsStopped {
                stoppedPill
                    .transition(.opacity)
            }
        }
        .animation(NookTheme.reveal, value: store.drivenBy)
        .animation(NookTheme.reveal, value: store.agentsStopped)
    }

    private func drivingPill(_ agent: String) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            AgentMark(agent: agent, account: nil, size: 14, ring: .clear)
            Text(tr(compact ? "browser.takeover.drivingShort" : "browser.takeover.driving", agent))
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.middle)
            SmallPrimaryButton(title: tr("browser.takeover.stop"), systemName: "stop.fill") { store.stopAgents() }
                .help(tr("browser.takeover.stopHelp"))
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
        .background(pillBackground)
        .padding(.bottom, compact ? NookTheme.Spacing.sm : NookTheme.Spacing.lg)
        .padding(.horizontal, NookTheme.Spacing.sm)
        .accessibilityElement(children: .contain)
    }

    private var stoppedPill: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(icon: "hand.raised.fill")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
            Text(tr("browser.takeover.stopped"))
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
            SmallGhostButton(title: tr("browser.takeover.allow")) { store.allowAgents() }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xxs)
        .padding(.vertical, NookTheme.Spacing.xxs)
        .background(pillBackground)
        .padding(.bottom, compact ? NookTheme.Spacing.sm : NookTheme.Spacing.lg)
        .padding(.horizontal, NookTheme.Spacing.sm)
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(NookTheme.surface)
            .overlay(Capsule(style: .continuous).stroke(NookTheme.fieldStroke, lineWidth: 1))
            .shadow(color: NookTheme.notch.opacity(0.45), radius: 14, y: 6)
    }
}
