import SwiftUI

/// The cross that closes a tab (a panel tab, a side panel tab, a terminal): a small bold `xmark` in a target larger than
/// the glyph, centered where the glyph is. `tint` nil keeps the tab's own text color, so the cross brightens with it
/// under the pointer. Hide it at rest with `.revealOnHover`.
struct TabCloseButton: View {
    /// The tooltip ("Close tab").
    let label: String
    /// What VoiceOver reads, when it should name the tab ("Close tab Changes"); the tooltip otherwise.
    var spoken: String? = nil
    /// The side of the square that takes the click.
    var target: CGFloat = 16
    var tint: Color? = NookTheme.textSecondary
    let action: () -> Void

    init(_ label: String, spoken: String? = nil, target: CGFloat = 16, tint: Color? = NookTheme.textSecondary,
         action: @escaping () -> Void) {
        self.label = label
        self.spoken = spoken
        self.target = target
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: target, height: target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .help(label)
        .accessibilityLabel(spoken ?? label)
    }

    @ViewBuilder private var glyph: some View {
        let cross = Image(icon: "xmark").font(NookTheme.font(9, .bold))
        if let tint {
            cross.foregroundStyle(tint)
        } else {
            cross
        }
    }
}
