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

    // Typography: SF Pro for text, SF Mono for code and paths.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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
