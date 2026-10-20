import SwiftUI

/// A tray tucked against the composer box, so it reads as coming out from behind it: under the box of a new session
/// (where it works and the branch it starts from), above the box of a running one (the pull request it watches and the
/// messages waiting in line). Put it next to the box in a `VStack(spacing: 0)` and give the box `.zIndex(1)`.
struct ComposerTray<Content: View>: View {
    /// The side of the box the tray comes out of.
    var edge: VerticalEdge = .bottom
    @ViewBuilder let content: Content

    /// How far the tray runs on behind the box.
    static var tuck: CGFloat { 14 }

    var body: some View {
        let inner: Edge.Set = edge == .bottom ? .top : .bottom
        let outer: Edge.Set = edge == .bottom ? .bottom : .top
        return content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(inner, Self.tuck + 4)
            .padding(outer, 4)
            .background(shape.fill(NookTheme.field))
            .overlay(shape.stroke(NookTheme.fieldStroke, lineWidth: 1))
            .padding(inner, -Self.tuck)
            .padding(.horizontal, 14)
    }

    private var shape: UnevenRoundedRectangle {
        let radius = NookTheme.Radius.sheet
        return edge == .bottom
            ? UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
    }
}

/// The hairline between two sections of one tray.
struct ComposerTrayDivider: View {
    var body: some View {
        Rectangle().fill(NookTheme.hairline).frame(height: 1).padding(.vertical, 2)
    }
}
