import SwiftUI

/// A symbol by name: an SF Symbol, or one of Nook's own pull request marks (`PullRequestStateGlyph`) named
/// `nook.pr.<glyph>`. Merging, a merged pull request and a merge conflict use these everywhere (buttons, menus, the
/// timeline, list rows), so they always look the same; never write `arrow.triangle.merge` or a warning triangle for them.
struct NookSymbol: View {
    let name: String
    /// The drawn marks' size; an SF Symbol takes the font around it.
    var size: CGFloat = 12

    init(_ name: String, size: CGFloat = 12) {
        self.name = name
        self.size = size
    }

    /// Merging, and a merged pull request.
    static let merge = "nook.pr.merged"
    /// A pull request that conflicts with its base.
    static let conflict = "nook.pr.conflict"
    /// An open pull request.
    static let open = "nook.pr.open"

    var body: some View {
        if name.hasPrefix("nook.pr."), let glyph = PullRequestBadge.Glyph(rawValue: String(name.dropFirst("nook.pr.".count))) {
            PullRequestStateGlyph(glyph: glyph, size: size, lineWidth: 1.5, nodeRadius: 1.8)
        } else {
            Image(systemName: name)
        }
    }
}
