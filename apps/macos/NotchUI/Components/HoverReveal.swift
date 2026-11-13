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

/// The chevron of a section that folds open: pointing right while closed, turned down while open, the same in every
/// disclosure (a tool step, a diff's file, a log, a settings group). It is decoration: the row it sits in carries the
/// label and the action, so it is hidden from VoiceOver.
struct DisclosureChevron: View {
    var open: Bool
    var size: CGFloat = 9
    var weight: Font.Weight = .bold
    var tint: Color = NookTheme.textTertiary

    var body: some View {
        Image(icon: "chevron.right")
            .font(NookTheme.font(size, weight))
            .foregroundStyle(tint)
            .rotationEffect(.degrees(open ? 90 : 0))
            .accessibilityHidden(true)
    }
}
