import SwiftUI

/// The one line a list shows when it has nothing to show ("No pull requests", "No matches"): the same size and color in
/// every list and tab. A whole panel without content uses `WSEmptyState` instead.
struct ListEmptyNote: View {
    let text: String
    var padding: CGFloat = 0

    init(_ text: String, padding: CGFloat = 0) {
        self.text = text
        self.padding = padding
    }

    var body: some View {
        Text(text)
            .font(NookTheme.font(12.5))
            .foregroundStyle(NookTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(padding)
    }
}
