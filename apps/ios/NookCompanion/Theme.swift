import SwiftUI
import UIKit

/// The companion's one design, after Nook on the Mac: a dark canvas, quiet raised surfaces, paper-white text, and colors
/// that keep their meaning everywhere (iris = Nook, mint = done, amber = waiting on you, coral = error, violet = merged).
/// Every view takes its colors, radii and spacing from here.
enum Theme {
    // MARK: Colors

    static let canvas = Color(hex: 0x0B0B0D)
    static let surface = Color(hex: 0x141417)
    static let raised = Color(hex: 0x1C1C21)
    static let hairline = Color(hex: 0x26262C)
    static let text = Color(hex: 0xF4F3F7)
    static let textSecondary = Color(hex: 0x9C9AA8)
    static let textTertiary = Color(hex: 0x6F6D7C)

    static let iris = Color(hex: 0x8C80FF)
    static let mint = Color(hex: 0x46E0A6)
    static let amber = Color(hex: 0xFFB84D)
    static let coral = Color(hex: 0xFF6B6B)
    static let violet = Color(hex: 0xB48CFF)

    // MARK: Shape and rhythm

    enum Radius {
        static let chip: CGFloat = 10
        static let control: CGFloat = 14
        static let card: CGFloat = 18
        static let bubble: CGFloat = 20
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: Session state

    /// What a session's `attention` means, in a few words and a color.
    static func color(_ attention: String) -> Color {
        switch attention {
        case "approval", "input", "limited": return amber
        case "failed": return coral
        case "working": return iris
        case "ready": return mint
        default: return textTertiary
        }
    }

    static func word(_ attention: String) -> String {
        switch attention {
        case "approval": return String(localized: "Waiting for approval")
        case "input": return String(localized: "Has a question")
        case "failed": return String(localized: "Failed")
        case "limited": return String(localized: "Limit reached")
        case "working": return String(localized: "Working")
        case "ready": return String(localized: "Ready")
        case "finished": return String(localized: "Finished")
        default: return String(localized: "Idle")
        }
    }

    static func symbol(_ attention: String) -> String {
        switch attention {
        case "approval": return "hand.raised.fill"
        case "input": return "questionmark.bubble.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "limited": return "hourglass"
        case "working": return "circle.dotted"
        case "ready": return "checkmark.circle.fill"
        case "finished": return "checkmark.circle"
        default: return "moon.zzz.fill"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Surfaces

extension View {
    /// A raised card on the canvas: the one container shape of the app.
    func card(padding: CGFloat = Theme.Spacing.lg, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.map { $0.opacity(0.10) } ?? Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(tint.map { $0.opacity(0.30) } ?? Theme.hairline, lineWidth: 1))
    }

    /// The dark canvas behind a whole screen, with matching bars.
    func screen() -> some View {
        self
            .background(Theme.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarBackground(Theme.surface, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

/// An uppercase heading above a group, with an optional count.
struct SectionHeader: View {
    let title: LocalizedStringKey
    var count: Int? = nil
    var color: Color = Theme.textTertiary

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title).textCase(.uppercase).tracking(0.8)
            if let count { Text(count, format: .number).monospacedDigit().foregroundStyle(Theme.textTertiary) }
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.top, Theme.Spacing.sm)
    }
}

/// A session's state as a small colored capsule; the dot breathes while the agent works.
struct StatusPill: View {
    let attention: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: Theme.symbol(attention))
                .symbolEffect(.pulse, isActive: attention == "working")
            Text(Theme.word(attention))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.color(attention))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.color(attention).opacity(0.14), in: Capsule())
    }
}

/// The mark of a coding agent: its own symbol and color in a rounded square.
struct AgentIcon: View {
    let agent: String
    var size: CGFloat = 36

    var body: some View {
        let style = Self.style(agent)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background(style.color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }

    /// By display name or id ("Claude Code" or "claude"), so sessions and the new-session sheet look the same.
    static func style(_ agent: String) -> (symbol: String, color: Color) {
        let name = agent.lowercased()
        if name.contains("claude") { return ("asterisk", Color(hex: 0xE38B6D)) }
        if name.contains("codex") { return ("chevron.left.forwardslash.chevron.right", Theme.text) }
        if name.contains("gemini") { return ("sparkle", Color(hex: 0x8AB4F8)) }
        if name.contains("opencode") { return ("terminal.fill", Theme.mint) }
        if name.contains("cursor") { return ("cursorarrow.rays", Theme.text) }
        if name.contains("grok") { return ("bolt.fill", Theme.text) }
        if name.contains("antigravity") { return ("atom", Theme.violet) }
        return ("cpu", Theme.iris)
    }
}

/// Nook's own mark: the iris glyph used for chats and the welcome screen.
struct NookMark: View {
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Theme.iris, Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A short notice across the width of the screen: offline, push not ready, no brain.
struct Banner: View {
    let text: String
    let symbol: String
    var color: Color = Theme.amber

    var body: some View {
        Label { Text(text).foregroundStyle(Theme.text) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .font(.footnote)
            .card(padding: Theme.Spacing.md, tint: color)
    }
}

/// An empty screen: a symbol, what it means, and what to do next.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.iris)
                .frame(width: 72, height: 72)
                .background(Theme.iris.opacity(0.12), in: Circle())
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            Text(message).font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            actions.padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

// MARK: Buttons

/// The one main action of a screen: a full-width iris capsule.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.iris

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// A compact action on a card (Allow, Deny, an answer).
struct ActionButtonStyle: ButtonStyle {
    var color: Color = Theme.text
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? Theme.canvas : color)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .frame(maxWidth: .infinity)
            .background(filled ? color : color.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A choice among a few: an agent or a folder in the new-session sheet.
struct ChoiceChip: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    var icon: AnyView? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                if let icon { icon }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.iris : Theme.textTertiary)
            }
            .padding(Theme.Spacing.md)
            .background(selected ? Theme.iris.opacity(0.12) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(selected ? Theme.iris.opacity(0.6) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A light tap for what you just did from the phone.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
