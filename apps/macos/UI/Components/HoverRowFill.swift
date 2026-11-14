import SwiftUI

/// The fill of a list row, a tab or a line in a card that lifts under the pointer: `NookTheme.rowFill` behind the
/// content (on a `NookTheme.Radius`, or square with `radius: nil`), `rowSelected` while selected, fading with
/// `NookTheme.hover`. It tracks the pointer itself, so a row whose hover only lights its fill needs no state of its own;
/// a row that also shows buttons or brightens its text under the pointer passes its own `hovering` binding.
struct HoverRowFill: ViewModifier {
    var selected = false
    var radius: CGFloat?
    var rest: Color = .clear
    var hovering: Binding<Bool>?
    @State private var ownHovering = false

    private var isHovering: Bool { hovering?.wrappedValue ?? ownHovering }

    func body(content: Content) -> some View {
        content
            .background {
                fill.animation(NookTheme.hover, value: isHovering)
            }
            .onHover { inside in
                guard inside != isHovering else { return }
                if let hovering { hovering.wrappedValue = inside } else { ownHovering = inside }
            }
    }

    @ViewBuilder private var fill: some View {
        let color = NookTheme.rowFill(selected: selected, hovering: isHovering, rest: rest)
        if let radius {
            NookTheme.shape(radius).fill(color)
        } else {
            Rectangle().fill(color)
        }
    }
}

extension View {
    /// A row's fill that lifts under the pointer (`HoverRowFill`); the row keeps no hover state of its own. `radius: nil`
    /// fills a square row edge to edge.
    func hoverRowFill(selected: Bool = false, radius: CGFloat? = NookTheme.Radius.control, rest: Color = .clear) -> some View {
        modifier(HoverRowFill(selected: selected, radius: radius, rest: rest))
    }

    /// The same fill for a row that uses its hover elsewhere too (buttons that show, a brighter title): it writes the
    /// pointer's state to `hovering`, which replaces the row's own `onHover`.
    func hoverRowFill(_ hovering: Binding<Bool>, selected: Bool = false, radius: CGFloat? = NookTheme.Radius.control,
                      rest: Color = .clear) -> some View {
        modifier(HoverRowFill(selected: selected, radius: radius, rest: rest, hovering: hovering))
    }
}
