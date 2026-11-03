import SwiftUI

/// The Usage page in the Agents tab: Cost and Tokens show every agent's usage on this Mac, as Settings › Coding agents
/// does. The subscription limits are a modal (`UsageLimitsSheet`), opened from the page's header.
struct AgentsUsagePanel: View {
    @EnvironmentObject private var app: AppModel
    /// Cost or Tokens, as the tabs of Settings › Coding agents.
    @AppStorage("usage.tab") private var tabRaw = UsageTab.cost.rawValue
    @AppStorage("usage.window") private var windowRaw = UsageWindow.week.rawValue
    @State private var showLimits = false

    enum UsageTab: String, CaseIterable, Hashable { case cost, tokens }

    /// A tab kept from before the limits moved to their modal reads as Cost.
    private var tab: UsageTab { UsageTab(rawValue: tabRaw) ?? .cost }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            PanelListHeader(tr("agents.footer.usage")) {
                SmallGhostButton(title: tr("limits.title")) { showLimits = true }
                    .help(tr("limits.openHelp"))
                UsageRefreshButton()
            }
            HStack(spacing: NookTheme.Spacing.md) {
                NookTabBar<UsageTab>(items: [
                    .init(value: .cost, title: tr("usage.metric.cost")),
                    .init(value: .tokens, title: tr("usage.metric.tokens")),
                ], selected: tab) { value in withAnimation(NookTheme.swap) { tabRaw = value.rawValue } }
                Spacer(minLength: 0)
                UsageWindowPicker(windowRaw: $windowRaw)
            }
            // The tabs line up with the page under them.
            .pageColumn()

            ScrollView(showsIndicators: false) {
                UsageInsightsPanel(history: app.history, metric: tab == .cost ? .cost : .tokens,
                                   window: UsageWindow(rawValue: windowRaw) ?? .week)
                    .padding(.bottom, NookTheme.Spacing.xl)
                    .pageColumn()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { app.history.refresh() }
        .sheet(isPresented: $showLimits) { UsageLimitsSheet().environmentObject(app) }
    }
}

/// Reads the limits of every account now, in the header of the usage panel and Settings › Coding agents. Shows a small spinner
/// until Claude Code has answered.
struct UsageRefreshButton: View {
    @EnvironmentObject private var app: AppModel
    @State private var refreshing = false

    var body: some View {
        if refreshing {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 24, height: 24)
                .help(tr("agents.usage.refreshing"))
        } else {
            ToolbarIconButton("arrow.clockwise", tr("agents.usage.refresh")) {
                refreshing = true
                Task {
                    await app.refreshQuotasManually()
                    refreshing = false
                }
            }
        }
    }
}
