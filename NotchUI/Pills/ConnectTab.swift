import SwiftUI

/// Everything Nook draws from at a glance: one tile per connection. Click a tile for details;
/// an amber dot indicates an item waiting for your attention.
struct ConnectTab: View {
    @ObservedObject var viewModel: NotchViewModel
    @EnvironmentObject private var app: AppModel
    @State private var selectedID: String?

    private var screen: ScreenContext { app.screenContext }

    var body: some View {
        // Reading `revision` ensures the tab updates whenever a connection has new data.
        let _ = app.connectors.revision
        let sources = app.connectors.sources.filter { $0.isActive || $0.status.state != .off }
        let selected = sources.first { $0.id == selectedID } ?? sources.first

        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                screenTile
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(sources.indices, id: \.self) { index in
                            ConnectorTile(source: sources[index], selected: sources[index].id == selected?.id) {
                                selectedID = sources[index].id
                            }
                        }
                        addTile
                    }
                }
            }
            .frame(width: 340)

            if let selected {
                ConnectorDetail(source: selected) { app.connectors.refresh(selected) }
            } else {
                emptyState
            }
        }
    }

    /// What Nook currently sees on your screens.
    private var screenTile: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(screen.windows.isEmpty ? NookTheme.textTertiary : NookTheme.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(screenHeadline)
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(screenDetail)
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12).fill(NookTheme.field))
    }

    private var screenHeadline: String {
        guard app.settings.liveScreen else { return tr("connect.screenOff") }
        guard screen.hasPermission else { return tr("connect.screenNoPermission") }
        if screen.windows.isEmpty { return tr("connect.screenLooking") }
        let displays = screen.displayCount
        return tr("connect.screenISee", screen.windows.count, displays > 1 ? tr("connect.screenDisplays", displays) : "")
    }

    private var screenDetail: String {
        guard app.settings.liveScreen, screen.hasPermission else { return tr("connect.screenEnableHint") }
        return screen.windows.prefix(4).map(\.app).joined(separator: " · ")
    }

    private var addTile: some View {
        Button { app.openSettings(section: .connections) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(tr("connect.addMore"))
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(tr("connect.addMoreServices"))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(NookTheme.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("connect.emptyTitle"))
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
            Text(tr("connect.emptyDetail"))
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ConnectorTile: View {
    let source: ContextSource
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let status = source.status
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 14)
                    Text(source.title)
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    stateDot(status)
                }
                Text(headline(status))
                    .font(NookTheme.font(13, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                Text(detail(status))
                    .font(NookTheme.font(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? NookTheme.smoke : (hovering ? NookTheme.graphite : NookTheme.field))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? source.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func headline(_ status: ConnectorStatus) -> String {
        switch status.state {
        case .off: return tr("connect.status.off")
        case .loading: return tr("connect.status.loading")
        case .error: return tr("connect.status.error")
        case .ok: return status.headline.isEmpty ? tr("connect.status.updated") : status.headline
        }
    }

    private func detail(_ status: ConnectorStatus) -> String {
        if case .error(let message) = status.state { return message }
        return status.detail
    }

    @ViewBuilder
    private func stateDot(_ status: ConnectorStatus) -> some View {
        let color: Color = {
            switch status.state {
            case .error: return NookTheme.coral
            case .off: return NookTheme.textTertiary
            default: return status.needsAttention ? NookTheme.amber : NookTheme.mint
            }
        }()
        Circle().fill(color).frame(width: 6, height: 6)
    }
}

/// Details for a connection: items with links if available, and prompt suggestions.
private struct ConnectorDetail: View {
    let source: ContextSource
    let refresh: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        let status = source.status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SiteIcon(domain: source.iconDomain, fallback: source.symbol, tint: source.accent, size: 18)
                Text(source.title)
                    .font(NookTheme.font(17, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Spacer()
                if let updated = status.updated {
                    Text(Self.ago(updated))
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                NookIconButton(systemName: "arrow.clockwise", label: tr("connect.refresh"), action: refresh)
            }

            if case .error(let message) = status.state {
                Text(message)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.coralSoft)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !status.detail.isEmpty {
                Text(status.detail)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.top, 4)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(status.items) { item in
                        ItemRow(item: item)
                    }
                }
            }
            .padding(.top, 10)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(Self.suggestions(for: source.id), id: \.self) { question in
                    Button { app.handleUserText(question) } label: {
                        Text(question)
                            .font(NookTheme.font(11.5, .medium))
                            .foregroundStyle(NookTheme.paper)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(NookTheme.smoke))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return tr("agents.justNow") }
        if seconds < 3600 { return tr("agents.minAgo", seconds / 60) }
        return tr("connect.atTime", NookDates.time(date))
    }

    /// Suggested questions you can ask with a single click.
    static func suggestions(for id: String) -> [String] {
        switch id {
        case "calendar": return [tr("connect.suggestion.calendar1"), tr("connect.suggestion.calendar2")]
        case "reminders": return [tr("connect.suggestion.reminders")]
        case "mail": return [tr("connect.suggestion.mail1"), tr("connect.suggestion.mail2")]
        case "browser": return [tr("connect.suggestion.browser")]
        case "files": return [tr("connect.suggestion.files")]
        case "github": return [tr("home.suggestions.github")]
        case "stripe": return [tr("connect.suggestion.stripe")]
        case "vercel": return [tr("connect.suggestion.vercel")]
        case "portfolio": return [tr("connect.suggestion.portfolio")]
        default: return [tr("connect.suggestion.default", id)]
        }
    }
}

private struct ItemRow: View {
    let item: ConnectorItem
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = item.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                if let domain = item.iconDomain {
                    SiteIcon(domain: domain, fallback: "link", tint: item.tone.color, size: 16)
                } else {
                    Circle().fill(item.tone.color).frame(width: 6, height: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if item.url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering && item.url != nil ? NookTheme.field : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
