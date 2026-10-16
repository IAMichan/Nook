import SwiftUI
import AppKit

// MARK: - Visual language of Settings
//
// One look everywhere: colored rounded-square tiles with a white symbol (like macOS System Settings), soft status
// pills, and numbered steps for anything that needs to be set up. Colors come from the Nook palette, so the
// settings feel like the same app as the notch.

extension SettingsSection {
    /// Filled symbol on the sidebar tile.
    var tileSymbol: String {
        switch self {
        case .general: return "house.fill"
        case .display: return "macwindow"
        case .brain: return "brain"
        case .assistant: return "sparkles"
        case .connections: return "app.connected.to.app.below.fill"
        case .mcp: return "puzzlepiece.extension.fill"
        case .agents: return "terminal.fill"
        case .privacy: return "hand.raised.fill"
        }
    }

    /// Top and bottom color of the tile gradient.
    var tileColors: (Color, Color) {
        switch self {
        case .general: return (Color(hex: 0x9D8FFF), Color(hex: 0x6C5CE7))
        case .display: return (Color(hex: 0x6CB6FF), Color(hex: 0x3478F6))
        case .brain: return (Color(hex: 0xF58FCB), Color(hex: 0xD24C9E))
        case .assistant: return (Color(hex: 0xFFC961), Color(hex: 0xF59E2E))
        case .connections: return (Color(hex: 0x5BE3B1), Color(hex: 0x1DB67F))
        case .mcp: return (Color(hex: 0x5ED6EE), Color(hex: 0x1FA2C6))
        case .agents: return (Color(hex: 0x62626F), Color(hex: 0x34343E))
        case .privacy: return (Color(hex: 0xFF8C8C), Color(hex: 0xE5505E))
        }
    }
}

/// A colored rounded square with a white symbol: the one icon style of Settings.
struct SettingsTile: View {
    let symbol: String
    let colors: (Color, Color)
    var size: CGFloat = 22

    init(symbol: String, colors: (Color, Color), size: CGFloat = 22) {
        self.symbol = symbol
        self.colors = colors
        self.size = size
    }

    init(_ section: SettingsSection, size: CGFloat = 22) {
        self.init(symbol: section.tileSymbol, colors: section.tileColors, size: size)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            )
            .frame(width: size, height: size)
    }
}

/// A brand icon (favicon) on a soft white tile, the same size and shape as `SettingsTile`, so services and
/// sections line up.
struct ServiceTile: View {
    let domain: String?
    let fallback: String
    var tint: Color = .secondary
    var size: CGFloat = 28
    /// The source id: a source backed by a Mac app shows that app's own icon instead of a tile.
    var source: String? = nil

    var body: some View {
        if let source, let app = SourceBrand.appIcon(for: source) {
            Image(nsImage: app)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 1.15, height: size * 1.15)
                .frame(width: size, height: size)
        } else {
            tile
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .overlay(
                SiteIcon(domain: domain, fallback: fallback, tint: tint, size: size * 0.62, source: source)
            )
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
    }
}

/// The state of a connection in plain words and one color.
enum ConnectionHealth: Equatable {
    case working, busy, off, needsYou, broken, notLinked

    var color: Color {
        switch self {
        case .working: return Color(hex: 0x1DB67F)
        case .busy: return NookTheme.iris
        case .off: return .secondary
        case .needsYou: return Color(hex: 0xF59E2E)
        case .broken: return Color(hex: 0xE5505E)
        case .notLinked: return .secondary
        }
    }

    var label: String {
        switch self {
        case .working: return tr("settings2.health.working")
        case .busy: return tr("settings2.health.busy")
        case .off: return tr("settings2.health.off")
        case .needsYou: return tr("settings2.health.needsYou")
        case .broken: return tr("settings2.health.broken")
        case .notLinked: return tr("settings2.health.notLinked")
        }
    }
}

/// Small colored capsule: "Werkt", "Uit", "Er gaat iets mis".
struct HealthPill: View {
    let health: ConnectionHealth
    var text: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if health == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(health.color).frame(width: 6, height: 6)
            }
            Text(text ?? health.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(health == .off || health == .notLinked ? Color.secondary : health.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(health.color.opacity(0.12)))
    }
}

/// A numbered step in a setup sheet: "1  Maak een sleutel".
struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    var done = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? ConnectionHealth.working.color : NookTheme.iris)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}

/// A rounded card used in the "add" galleries.
struct GalleryCard<Icon: View, Accessory: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var accessory: () -> Accessory
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    icon()
                    Spacer(minLength: 4)
                    accessory()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The grid the gallery cards sit in.
struct GalleryGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 10)], spacing: 10) {
            content()
        }
        .padding(.vertical, 4)
    }
}

/// A friendly explanation at the top of a page: one sentence, one symbol.
struct IntroCard: View {
    let symbol: String
    let colors: (Color, Color)
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsTile(symbol: symbol, colors: colors, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// Sheet chrome shared by every setup sheet: big icon and title on top, content, and one clear button at the bottom.
struct SetupSheet<Icon: View, Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                footer()
            }
            .padding(16)
        }
        .frame(width: 520)
        .frame(minHeight: 360, idealHeight: 520, maxHeight: 680)
    }
}
