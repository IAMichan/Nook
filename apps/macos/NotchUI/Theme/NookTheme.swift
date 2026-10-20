import SwiftUI
import AppKit

extension Color {
    /// Creates a color from a hex integer, e.g. `Color(hex: 0x8B7BFF)`.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Nook design system. Color consistently represents state:
/// iris = Nook itself, mint = listening or done, amber = waiting on you, coral = error.
enum NookTheme {
    // Colors
    static let notch = Color.black
    static let graphite = Color(hex: 0x16161B)
    static let smoke = Color(hex: 0x22222A)
    static let field = Color(hex: 0x0F0F13)
    static let line = Color(hex: 0x1A1A20)
    static let line2 = Color(hex: 0x2C2C36)

    static let paper = Color(hex: 0xF4F3F7)
    static let ink = Color(hex: 0x0B0A12)
    static let eyeInk = Color(hex: 0x050507)
    static let textSecondary = Color(hex: 0x9C9AA8)
    static let textTertiary = Color(hex: 0x6F6D7C)

    /// Nook's own color. Soft white by default; the user can pick another in Settings › Appearance.
    static let defaultAccentHex: UInt32 = 0xF4F3F7
    /// Current accent (kept in sync by `AppSettings.accentHex`).
    static var accentHex: UInt32 = defaultAccentHex
    static var iris: Color { Color(hex: accentHex) }
    /// Text and symbols on an iris fill: dark on a light accent (the default soft white), white on a deep one.
    static var onIris: Color { relativeLuminance(accentHex) > 0.45 ? ink : .white }

    /// WCAG relative luminance of a 0xRRGGBB color, 0 (black) to 1 (white).
    static func relativeLuminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }
    static let mint = Color(hex: 0x46E0A6)
    static let amber = Color(hex: 0xFFB84D)
    static let coral = Color(hex: 0xFF6B6B)
    static let coralSoft = Color(hex: 0xFF8A8A)
    /// A merged pull request, as forges show it.
    static let violet = Color(hex: 0xB48CFF)
    static let mintSoft = Color(hex: 0x5FE3B0)
    static let music = Color(hex: 0xFF8A5B)

    /// The canvas behind every window: the Workspace, Settings, and the Today window share it.
    static let canvas = Color(hex: 0x0B0B0D)
    /// A sunken well inside a card: code, logs, and the composer tray.
    static let well = Color(hex: 0x0A0A0D)
    /// A lifted surface: sidebars, menus, the composer.
    static let surface = Color(hex: 0x121214)
    /// The faintest divider between regions of a panel.
    static let hairline = Color(hex: 0x19191B)
    /// The stroke of a text field or tray at rest.
    static let fieldStroke = Color(hex: 0x222226)
    /// Body text that reads a little softer than `paper`, without dropping to `textSecondary`.
    static let textStrong = Color(hex: 0xD9D7E0)
    /// Muted text that shimmers or sits in a disabled control.
    static let textMuted = Color(hex: 0x8A8896)
    /// Links, renamed files, and diff hunk headers.
    static let blue = Color(hex: 0x8AB4F8)

    // List rows and cards: at rest, under the pointer, and selected.
    static let rowRest = Color(hex: 0x09090A)
    static let rowHover = Color(hex: 0x111113)
    static let rowSelected = Color(hex: 0x17171A)

    /// The fill of a list row: `rowSelected` when selected, `rowHover` under the pointer, `rest` otherwise.
    static func rowFill(selected: Bool, hovering: Bool, rest: Color = rowRest) -> Color {
        selected ? rowSelected : (hovering ? rowHover : rest)
    }

    /// Corner radii. Pick the token that names the element, not the number: a chip inside a card is always rounder
    /// than a hairline and flatter than the card.
    enum Radius {
        /// Tags, keycaps, and inline code.
        static let chip: CGFloat = 6
        /// Buttons, text fields, and toolbar items.
        static let control: CGFloat = 8
        /// Cards, rows, and notices.
        static let card: CGFloat = 10
        /// Panels, popovers, and menus.
        static let panel: CGFloat = 12
        /// Sheets and the composer tray.
        static let sheet: CGFloat = 14
        /// Pills and the notch's own corners.
        static let pill: CGFloat = 20
    }

    /// Spacing on a 4 pt grid. Use these for padding and stack spacing so the panels line up.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    /// The type scale: five sizes, each with its weight, so two panels never show the same kind of text at
    /// different sizes. Use `font(_:_:)` only for the odd size that these do not cover (a numeral, an icon).
    enum TextStyle {
        /// Captions, timestamps, and section titles in uppercase.
        static var caption: Font { NookTheme.font(10.5, .medium) }
        /// Secondary labels, badges, and metadata.
        static var label: Font { NookTheme.font(11.5, .medium) }
        /// Body text in rows, cards, and chat.
        static var body: Font { NookTheme.font(13) }
        /// A row title or a button.
        static var strong: Font { NookTheme.font(13, .semibold) }
        /// The title of a panel or a card.
        static var title: Font { NookTheme.font(15, .semibold) }
        /// Inline code and paths at body size.
        static var code: Font { NookTheme.mono(12) }
    }

    // Typography: SF Pro for text, SF Mono for code and paths.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Rounded: only for a numeral in a badge or a step counter, never for running text.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // Animation. Opening has a subtle overshoot; closing is smooth without bounce.
    static let open = Animation.spring(duration: 0.42, bounce: 0.25)
    static let close = Animation.spring(duration: 0.3, bounce: 0)
    /// Tab switching within the same panel: tighter and snappier.
    static let swap = Animation.spring(duration: 0.28, bounce: 0.12)
    /// Hover feedback on buttons and chips: quick, with a hint of spring.
    static let hover = Animation.spring(duration: 0.2, bounce: 0.1)
    static let spring = open
}

/// Lifts a control a little while the pointer is on it (see `View.hoverLift`). With Reduce Motion on it stays put: the
/// color change alone says that it is live.
private struct HoverLift: ViewModifier {
    var hovering: Bool
    var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .animation(NookTheme.hover, value: hovering)
    }
}

extension View {
    /// The shared hover state of Nook's buttons and chips: a slight lift with `NookTheme.hover`, none with Reduce Motion.
    func hoverLift(_ hovering: Bool, scale: CGFloat = 1.02) -> some View {
        modifier(HoverLift(hovering: hovering, scale: scale))
    }
}

/// Notch content: appears slightly after the shape (snappy fade-in) and dismisses quickly.
private struct NotchContentFade: ViewModifier {
    var amount: CGFloat   // 1 = gone, 0 = visible
    func body(content: Content) -> some View {
        content
            .opacity(1 - Double(amount))
            .blur(radius: amount * 6)
            .scaleEffect(1 - amount * 0.035, anchor: .top)
    }
}

extension AnyTransition {
    static var notchContent: AnyTransition {
        // Reduce Motion: a plain fade, without the blur and the scale.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.09)),
                               removal: .opacity.animation(.easeIn(duration: 0.12)))
        }
        return .asymmetric(
            insertion: .modifier(active: NotchContentFade(amount: 1), identity: NotchContentFade(amount: 0))
                .animation(.easeOut(duration: 0.34).delay(0.09)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }
}
