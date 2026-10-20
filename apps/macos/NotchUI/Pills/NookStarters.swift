import SwiftUI

// The empty chat's building blocks: conversation starters and the rows of your day.

/// Suggested conversation starters, two per row so a long one never runs off the side.
struct SuggestionGrid: View {
    let suggestions: [StartSuggestion]
    let ask: (StartSuggestion) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(suggestions) { suggestion in
                SuggestionCard(suggestion: suggestion) { ask(suggestion) }
            }
        }
    }
}

/// One starter: the icon of what it is about and the question; it brightens and shows an arrow under the pointer.
private struct SuggestionCard: View {
    let suggestion: StartSuggestion
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HomeLogo(logo: suggestion.logo, tint: NookTheme.textSecondary, size: 26)
                Text(suggestion.text)
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(hovering ? NookTheme.graphite : NookTheme.field))
            .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
                .stroke(hovering ? NookTheme.line2 : NookTheme.line2.opacity(0.6), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The icon in front of a Today row or a starter, always in a box of the same size so the text beside it lines up:
/// a connection's own icon, an agent's logo, or a symbol on a soft tile in the item's color.
private struct HomeLogo: View {
    let logo: TodayItem.Logo?
    var tint: Color
    var size: CGFloat = 30
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch logo {
            case .agent(let name):
                AgentLogo(agent: name, size: size * 0.62)
            case .source(let id):
                let source = app.connectors.source(id: id)
                SiteIcon(domain: source?.iconDomain, fallback: source?.symbol ?? "circle.grid.2x2", tint: tint, size: size * 0.62, source: id)
            case .symbol(let name):
                Image(systemName: name)
                    .font(NookTheme.font(size * 0.42, .medium))
                    .foregroundStyle(tint)
            case nil:
                Circle().fill(tint).frame(width: 8, height: 8)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tileFill))
    }

    /// Symbols and dots sit on a tile tinted with their color; real icons get a neutral one.
    private var tileFill: Color {
        switch logo {
        case .symbol, nil: return tint.opacity(0.12)
        case .agent, .source: return NookTheme.paper.opacity(0.05)
        }
    }
}

struct TodayRow: View {
    let item: TodayItem
    let action: () -> Void
    @State private var hovering = false

    /// A connection or agent keeps its own icon, with the item's color as a small dot on its corner.
    private var hasBadge: Bool {
        switch item.logo {
        case .agent, .source: return true
        case .symbol, nil: return false
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HomeLogo(logo: item.logo, tint: item.color)
                    .overlay(alignment: .bottomTrailing) {
                        if hasBadge {
                            Circle().fill(item.color).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(NookTheme.field, lineWidth: 1.5))
                                .offset(x: 2, y: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NookTheme.font(13.5, .medium))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !item.action.isEmpty {
                    HStack(spacing: 4) {
                        Text(item.action)
                            .font(NookTheme.font(12, .medium))
                        Image(systemName: "chevron.right")
                            .font(NookTheme.font(9.5, .semibold))
                    }
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.paper.opacity(0.05)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(hovering ? NookTheme.paper.opacity(0.03) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
