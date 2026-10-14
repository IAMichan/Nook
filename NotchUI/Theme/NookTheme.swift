import SwiftUI

extension Color {
    /// Maakt een kleur uit een hex-waarde, bijvoorbeeld `Color(hex: 0x8B7BFF)`.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Huisstijl van Nook. Kleur betekent altijd een toestand:
/// iris = Nook zelf, mint = luistert of klaar, amber = wacht op jou, koraal = fout.
enum NookTheme {
    // Kleuren
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

    static let iris = Color(hex: 0x8B7BFF)
    static let mint = Color(hex: 0x46E0A6)
    static let amber = Color(hex: 0xFFB84D)
    static let coral = Color(hex: 0xFF6B6B)
    static let coralSoft = Color(hex: 0xFF8A8A)
    static let mintSoft = Color(hex: 0x5FE3B0)
    static let music = Color(hex: 0xFF8A5B)

    // Lettertypen: SF Pro voor tekst, SF Mono voor code en paden.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Beweging. Openen veert een heel klein beetje door; sluiten is rustig en zonder stuiter.
    static let open = Animation.spring(duration: 0.52, bounce: 0.2)
    static let close = Animation.spring(duration: 0.4, bounce: 0)
    /// Wisselen binnen hetzelfde paneel (tabs): kleiner, strakker.
    static let swap = Animation.spring(duration: 0.38, bounce: 0.08)
    static let spring = open
}

/// Inhoud van de notch: komt iets later binnen dan de vorm (scherp, dan zacht), en verdwijnt snel.
private struct NotchContentFade: ViewModifier {
    var amount: CGFloat   // 1 = weg, 0 = zichtbaar
    func body(content: Content) -> some View {
        content
            .opacity(1 - Double(amount))
            .blur(radius: amount * 6)
            .scaleEffect(1 - amount * 0.035, anchor: .top)
    }
}

extension AnyTransition {
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: NotchContentFade(amount: 1), identity: NotchContentFade(amount: 0))
                .animation(.easeOut(duration: 0.34).delay(0.09)),
            removal: .opacity.animation(.easeIn(duration: 0.12))
        )
    }
}
