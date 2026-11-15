import SwiftUI

extension View {
    /// A menu that is only its label (a ⋯, a chip, a title with its own chevron): Nook's borderless menu style with the
    /// pointing hand, no system indicator, and as wide as its label.
    func nookMenuButton() -> some View {
        menuStyle(.nookBorderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    /// A switch in a row or a card, a step smaller than the system's: `.small` beside a row's text, `.mini` inside a
    /// dense card or a composer.
    func compactSwitch(_ size: ControlSize = .small) -> some View {
        toggleStyle(.switch)
            .controlSize(size)
    }
}
