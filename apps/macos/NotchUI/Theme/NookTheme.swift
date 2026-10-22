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
///
/// Calm by design: every surface sits on one neutral grey ramp, a step apart, so regions read by their fill and need
/// almost no strokes; strokes are only a shade lighter than what they edge; state colors are a little softened so a
/// badge informs without shouting. Change a token here and every panel, card and setting follows.
enum NookTheme {
    // Colors: the surface ramp, darkest to lightest.
    static let notch = Color.black
    static let graphite = Color(hex: 0x17171A)
    static let smoke = Color(hex: 0x1F1F23)
    static let field = Color(hex: 0x111113)
    static let line = Color(hex: 0x18181B)
    static let line2 = Color(hex: 0x232327)

    static let paper = Color(hex: 0xF2F2F4)
    static let ink = Color(hex: 0x0B0B0D)
    static let eyeInk = Color(hex: 0x050507)
    static let textSecondary = Color(hex: 0x98989F)
    static let textTertiary = Color(hex: 0x6C6C74)

    /// Nook's own color. Soft white by default; the user can pick another in Settings › Appearance.
    static let defaultAccentHex: UInt32 = 0xF2F2F4
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
    static let mint = Color(hex: 0x5ED6A6)
    static let amber = Color(hex: 0xF2B866)
    static let coral = Color(hex: 0xEF7B73)
    static let coralSoft = Color(hex: 0xF29A92)
    /// A merged pull request, as forges show it.
    static let violet = Color(hex: 0xAE94F2)
    static let mintSoft = Color(hex: 0x74DDB3)
    static let music = Color(hex: 0xF0936A)

    /// The canvas behind every window: the Workspace, Settings, and the Today window share it.
    static let canvas = Color(hex: 0x0C0C0E)
    /// A sunken well inside a card: code, logs, and the composer tray.
    static let well = Color(hex: 0x0A0A0C)
    /// A lifted surface: sidebars, menus, the composer.
    static let surface = Color(hex: 0x131315)
    /// The faintest divider between regions of a panel.
    static let hairline = Color(hex: 0x18181B)
    /// The stroke of a text field or tray at rest.
    static let fieldStroke = Color(hex: 0x1D1D21)
    /// Body text that reads a little softer than `paper`, without dropping to `textSecondary`.
    static let textStrong = Color(hex: 0xD4D4D9)
    /// Muted text that shimmers or sits in a disabled control.
    static let textMuted = Color(hex: 0x86868E)
    /// Links, renamed files, and diff hunk headers.
    static let blue = Color(hex: 0x8FB3F0)

    // List rows and cards: at rest, under the pointer, and selected.
    static let rowRest = Color(hex: 0x0A0A0B)
    static let rowHover = Color(hex: 0x141416)
    static let rowSelected = Color(hex: 0x1A1A1D)

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
        /// Between the sections of a page (home, a settings page): room that groups without a line.
        static let xxxl: CGFloat = 32
    }

    /// The type scale: each kind of text with its size and weight, so two panels never show the same kind of text at
    /// different sizes. Running text is a `TextStyle`; use `font(_:_:)` only for a symbol's size or a numeral the scale
    /// does not cover. Sizes lean a little large on purpose: Nook is read at a glance, often from the notch.
    ///
    /// Picking one: a timestamp or a count is `caption`; the line under a title (a hint, a setting's explanation, a
    /// row's second line) is `detail`; a badge, a chip or metadata is `label`; what you read is `body`; a row's title
    /// or a button is `strong`; a panel's or card's title is `title`; a sheet's or a step's heading is `heading`; the one
    /// big line on a page (home's greeting, a settings page) is `display`.
    enum TextStyle {
        /// Timestamps, counts, and the smallest metadata.
        static var caption: Font { NookTheme.font(11, .medium) }
        /// The line under a title: a setting's explanation, a hint, a row's second line, or an error message.
        static var detail: Font { NookTheme.font(12) }
        /// Secondary labels, badges, chips, and metadata.
        static var label: Font { NookTheme.font(12, .medium) }
        /// Body text in rows, cards, and chat.
        static var body: Font { NookTheme.font(13.5) }
        /// A row title or a button.
        static var strong: Font { NookTheme.font(13.5, .semibold) }
        /// The title of a panel, a list, or a card.
        static var title: Font { NookTheme.font(15, .semibold) }
        /// The heading of a sheet or a setup step.
        static var heading: Font { NookTheme.font(18, .semibold) }
        /// The one large line of a page: home's greeting, a settings page's title.
        static var display: Font { NookTheme.font(22, .semibold) }
        /// Inline code and paths at body size.
        static var code: Font { NookTheme.mono(12.5) }
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

    // Animation. Every curve is a spring: a spring keeps its velocity when it is interrupted (hover off before the
    // hover in finished, a tab picked while the last one still slides), where a timing curve restarts from rest and
    // visibly jerks. Opening has a subtle overshoot; closing is smooth without bounce.
    static let open = Animation.spring(duration: 0.42, bounce: 0.08)
    static let close = Animation.spring(duration: 0.3, bounce: 0)
    /// Tab switching within the same panel: tighter, and without overshoot so the content does not wobble.
    static let swap = Animation.spring(duration: 0.28, bounce: 0)
    /// Hover feedback on buttons and chips: quick and settled.
    static let hover = Animation.spring(duration: 0.2, bounce: 0)
    /// Showing or hiding part of a panel: a section that expands, a preview or side panel, a selection that changes.
    static let reveal = Animation.spring(duration: 0.24, bounce: 0)
    /// Scrolling a list to a message or a line.
    static let scroll = Animation.spring(duration: 0.3, bounce: 0)
    static let spring = open
}

/// Lifts a control a hair while the pointer is on it (see `View.hoverLift`). With Reduce Motion on it stays put: the
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
    func hoverLift(_ hovering: Bool, scale: CGFloat = 1.01) -> some View {
        modifier(HoverLift(hovering: hovering, scale: scale))
    }
}

/// Notch content: appears slightly after the shape (snappy fade-in) and dismisses quickly.
/// Opacity and scale only: both are composited as they are, where a blur renders the whole panel offscreen again on
/// every frame of the opening, which is where it stuttered.
private struct NotchContentFade: ViewModifier {
    var amount: CGFloat   // 1 = gone, 0 = visible
    func body(content: Content) -> some View {
        content
            .opacity(1 - Double(amount))
            .scaleEffect(1 - amount * 0.03, anchor: .top)
            .offset(y: -amount * 4)
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
                .animation(.spring(duration: 0.36, bounce: 0).delay(0.08)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }
}
