import SwiftUI

/// A tray tucked against the composer box, so it reads as coming out from behind it: under the box of a new session
/// (where it works and the branch it starts from), above the box of a running one (the pull request it watches and the
/// messages waiting in line). Put it next to the box in a `VStack(spacing: 0)` and give the box `.zIndex(1)`.
struct ComposerTray<Content: View>: View {
    /// The side of the box the tray comes out of.
    var edge: VerticalEdge = .bottom
    @ViewBuilder let content: Content

    /// How far the tray runs on behind the box.
    static var tuck: CGFloat { 16 }

    var body: some View {
        let inner: Edge.Set = edge == .bottom ? .top : .bottom
        let outer: Edge.Set = edge == .bottom ? .bottom : .top
        return content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(inner, Self.tuck + 4)
            .padding(outer, 4)
            .background(shape.fill(NookTheme.field))
            .overlay(shape.strokeBorder(NookTheme.fieldStroke, lineWidth: 1))
            .padding(inner, -Self.tuck)
            // Narrower than the box by a little more than its corner, so the tray clearly comes out from behind it.
            .padding(.horizontal, NookTheme.Spacing.xl + NookTheme.Spacing.sm)
    }

    private var shape: UnevenRoundedRectangle {
        let radius = NookTheme.Radius.composer
        return edge == .bottom
            ? UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
    }
}

/// The hairline between two sections of one tray.
struct ComposerTrayDivider: View {
    var body: some View {
        NookDivider().padding(.vertical, 2)
    }
}

/// Why the last thing you did at a composer failed (a file the chat could not read, an agent's action that did not go
/// through), right next to that box instead of as a card in the notch. With `dismiss` it has a close button.
struct ComposerErrorLine: View {
    let message: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            Image(icon: "exclamationmark.triangle.fill")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coral)
            Text(message)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coralSoft)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                ToolbarIconButton("xmark", tr("button.clear"), height: 18, width: 18, dismiss)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
