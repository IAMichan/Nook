import SwiftUI

/// A symbol by name: an SF Symbol, or one of Nook's own pull request marks (`PullRequestStateGlyph`) named
/// `nook.pr.<glyph>`. Take pull request names from `PullRequestIcon` (a state, `generic` for pull requests in general),
/// so they always look the same; never write `arrow.triangle.merge`, `arrow.triangle.pull` or a warning triangle for them.
struct NookSymbol: View {
    let name: String
    /// The drawn marks' size; an SF Symbol takes the font around it.
    var size: CGFloat = 12

    init(_ name: String, size: CGFloat = 12) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if name.hasPrefix("nook.pr."), let glyph = PullRequestBadge.Glyph(rawValue: String(name.dropFirst("nook.pr.".count))) {
            PullRequestStateGlyph(glyph: glyph, size: size, lineWidth: size < 14 ? 1.6 : 1.4, nodeRadius: size < 14 ? 1.8 : 1.7)
        } else {
            Image(systemName: name)
        }
    }
}
