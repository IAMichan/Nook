import SwiftUI

extension View {
    /// A control that shows only under the pointer (a row's close, edit, open or more button, as "Show at rest only what
    /// you use most" asks): invisible at rest and out of the way of clicks, fading in with `NookTheme.hover` when
    /// `animated`. Never write `.opacity(hovering ? 1 : 0)` by hand: without `allowsHitTesting` a hidden button can still
    /// be clicked.
    func revealOnHover(_ shown: Bool, animated: Bool = false) -> some View {
        modifier(RevealOnHover(shown: shown, animated: animated))
    }
}

private struct RevealOnHover: ViewModifier {
    let shown: Bool
    let animated: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(animated ? NookTheme.hover : nil, value: shown)
    }
}

/// The small mark at the end of a row that says where a click goes (`arrow.up.right` opens a link, `chevron.right` a
/// page): `textTertiary`, shown only while the pointer is on the row, so a list at rest stays free of them. Decoration:
/// the row carries the label, so it is hidden from VoiceOver. Never `.opacity(hovering ? 1 : 0)` on a glyph by hand.
struct HoverGlyph: View {
    let icon: String
    let shown: Bool
    var size: CGFloat = 10
    var weight: Font.Weight = .semibold

    init(_ icon: String, shown: Bool, size: CGFloat = 10, weight: Font.Weight = .semibold) {
        self.icon = icon
        self.shown = shown
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Image(icon: icon)
            .font(NookTheme.font(size, weight))
            .foregroundStyle(NookTheme.textTertiary)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// The chevron of a section that folds open: pointing right while closed, turned down while open, the same in every
/// disclosure (a tool step, a diff's file, a log, a settings group). `.vertical` is for a list that grows below its
/// header ("Show 3 more", resolved threads): down while closed, up while open; `.upward` for a shelf that opens above
/// it. `tint` nil keeps the row's own color, so the chevron brightens with the row under the pointer. It is decoration:
/// the row it sits in carries the label and the action, so it is hidden from VoiceOver.
struct DisclosureChevron: View {
    enum Style {
        /// Right while closed, down while open.
        case side
        /// Down while closed, up while open.
        case vertical
        /// Up while closed, down while open: a shelf that opens upwards, above its header.
        case upward

        var icon: String {
            switch self {
            case .side: return "chevron.right"
            case .vertical: return "chevron.down"
            case .upward: return "chevron.up"
            }
        }

        var openAngle: Double { self == .side ? 90 : 180 }
    }

    var open: Bool
    var size: CGFloat = 9
    var weight: Font.Weight = .bold
    var tint: Color? = NookTheme.textTertiary
    var style: Style = .side

    var body: some View {
        glyph
            .rotationEffect(.degrees(open ? style.openAngle : 0))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        let image = Image(icon: style.icon).font(NookTheme.font(size, weight))
        if let tint {
            image.foregroundStyle(tint)
        } else {
            image
        }
    }
}
