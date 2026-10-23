import ActivityKit
import SwiftUI
import WidgetKit

// The widget extension: one Live Activity per session that works on the Mac, on the Lock Screen and in the Dynamic
// Island (docs/COMPANION.md › Live Activities). The Mac starts, updates and ends it with pushes; the app does the same
// while it is open.

@main
struct NookActivityBundle: WidgetBundle {
    var body: some Widget {
        NookLiveActivity()
    }
}

struct NookLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NookActivityAttributes.self) { context in
            let look = ActivityLook(context.attributes, context.state, stale: context.isStale)
            LockScreenActivity(look: look)
                .activityBackgroundTint(Theme.canvas.opacity(0.92))
                .activitySystemActionForegroundColor(Theme.text)
                .widgetURL(ActivityLink.url(session: context.attributes.session))
        } dynamicIsland: { context in
            let look = ActivityLook(context.attributes, context.state, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(look.agent).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    } icon: {
                        Image(systemName: look.symbol).foregroundStyle(look.color)
                    }
                    .padding(.leading, Theme.Spacing.xs)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseLine(look: look).padding(.trailing, Theme.Spacing.xs)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(look.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                        if !look.detail.isEmpty {
                            Text(look.detail).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xs)
                }
            } compactLeading: {
                Image(systemName: look.symbol).foregroundStyle(look.color)
            } compactTrailing: {
                if look.counts {
                    Text(look.since, style: .timer).monospacedDigit().foregroundStyle(look.color).frame(maxWidth: 44)
                } else {
                    Text(look.word).font(.caption2.weight(.semibold)).foregroundStyle(look.color).lineLimit(1)
                        .minimumScaleFactor(0.6).frame(maxWidth: 64)
                }
            } minimal: {
                Image(systemName: look.symbol).foregroundStyle(look.color)
            }
            .widgetURL(ActivityLink.url(session: context.attributes.session))
            .keylineTint(look.color)
        }
    }
}

/// What an activity shows, worked out once for every presentation.
struct ActivityLook {
    let agent: String
    let title: String
    /// Folder and model: "nook · claude-sonnet-4-5".
    let detail: String
    let word: String
    let symbol: String
    let color: Color
    let since: Date
    /// A timer runs (working, and the Mac still answers).
    let counts: Bool

    init(_ attributes: NookActivityAttributes, _ state: LiveActivityContent, stale: Bool) {
        agent = attributes.agent
        let title = state.title.isEmpty ? attributes.title : state.title
        self.title = title.isEmpty ? attributes.agent : title
        detail = [attributes.project, state.model].filter { !$0.isEmpty }.joined(separator: " · ")
        since = Date(timeIntervalSince1970: state.since)
        // Past the stale date the Mac has not said anything for a while (asleep, offline, quit): no spinner that claims
        // the agent still works. A finished result stays as it was.
        if stale, !state.phase.isFinished {
            word = String(localized: "Out of date")
            symbol = "clock.arrow.circlepath"
            color = Theme.textSecondary
            counts = false
        } else {
            word = state.phase.word
            symbol = state.phase.symbol
            color = state.phase.color
            counts = state.phase == .working
        }
    }
}

private struct PhaseLine: View {
    let look: ActivityLook

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(look.word).font(.caption.weight(.semibold)).foregroundStyle(look.color).lineLimit(1)
            if look.counts {
                Text(look.since, style: .timer).font(.caption).monospacedDigit().foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct LockScreenActivity: View {
    let look: ActivityLook

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            Image(systemName: look.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(look.color)
                .frame(width: 36, height: 36)
                .background(look.color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(look.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                Text([look.agent, look.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.md)
            PhaseLine(look: look)
        }
        .padding(Theme.Spacing.xl)
    }
}
