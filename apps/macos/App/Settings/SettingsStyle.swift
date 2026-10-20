import SwiftUI
import AppKit

// MARK: - Visual language of Settings
//
// One look everywhere: quiet graphite tiles with a light symbol, soft status pills, and numbered steps for anything that
// needs to be set up. Everything comes from the Nook palette (near-black, soft white, a little mint, amber and coral for
// state), so the settings feel like the same app as the notch.

extension SettingsSection {
    /// Filled symbol on the sidebar tile.
    var tileSymbol: String {
        switch self {
        case .start: return "house.fill"
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .shortcuts: return "command"
        case .notifications: return "bell.fill"
        case .brain: return "brain"
        case .assistant: return "sparkles"
        case .memory: return "brain.head.profile"
        case .autocomplete: return "text.cursor"
        case .dictation: return "mic.fill"
        case .connections: return "app.connected.to.app.below.fill"
        case .agents: return "terminal.fill"
        case .usage: return "chart.bar.fill"
        case .workspace: return "folder.fill"
        case .devices: return "iphone"
        case .privacy: return "hand.raised.fill"
        }
    }

    /// Top and bottom color of the tile gradient. Tiles themselves are graphite now; a few charts still take the color.
    var tileColors: (Color, Color) {
        switch self {
        case .autocomplete: return (Color(hex: 0x8FE3FF), Color(hex: 0x2FA8D8))
        case .memory: return (Color(hex: 0xB9AEFF), Color(hex: 0x8B7CF6))
        default: return (NookTheme.smoke, NookTheme.graphite)
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

    /// `colors` is kept for the callers that still pass one: every tile has the same quiet look now.
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [NookTheme.smoke, NookTheme.graphite], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(NookTheme.line2, lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(NookTheme.font(size * 0.5, .medium))
                    .foregroundStyle(NookTheme.paper.opacity(0.92))
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
        case .working: return NookTheme.mint
        case .busy: return NookTheme.iris
        case .off: return .secondary
        case .needsYou: return NookTheme.amber
        case .broken: return NookTheme.coral
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
                    Image(systemName: "checkmark").font(NookTheme.font(11, .bold))
                } else {
                    Text("\(number)").font(NookTheme.rounded(12, .bold))
                }
            }
            .foregroundStyle(done ? NookTheme.ink : NookTheme.onIris)
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
                RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
                    .strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
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

/// A friendly explanation at the top of a page, under the header that already shows the section's icon.
struct IntroCard: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
