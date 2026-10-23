import SwiftUI

/// A pull request label: a dot in the label's own GitHub color and its name in a faint capsule.
/// Used on list rows, on a pull request's Summary, and in the Labels filter.
struct LabelChip: View {
    let name: String
    /// GitHub's six hex digits; a label without one gets a grey dot.
    var color: String? = nil
    /// Text after the name ("+2" for labels that did not fit).
    var suffix: String? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            LabelDot(color: color)
            Text(name).lineLimit(1).truncationMode(.tail)
            if let suffix { Text(suffix).foregroundStyle(NookTheme.textTertiary).fixedSize() }
        }
        .font(NookTheme.TextStyle.caption)
        .foregroundStyle(NookTheme.textSecondary)
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, 1)
        .background(Capsule().strokeBorder(NookTheme.line2))
        .help(name)
    }
}

/// The colored dot of a label.
struct LabelDot: View {
    var color: String?
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(Color(hexString: color) ?? NookTheme.textTertiary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A GitHub account's picture, read from GitHub by login; its initials until the picture is in, or when there is none.
struct GitHubAvatar: View {
    let login: String
    var size: CGFloat = 16

    private var url: URL? {
        guard !login.isEmpty, !login.hasSuffix("[bot]"),
              let name = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(name)?s=\(Int(size * 2))")
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ChatPersonBadge(name: login, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

/// Chips in rows that wrap to the width they are given (a pull request's labels).
struct ChipFlow: Layout {
    var spacing: CGFloat = NookTheme.Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, view) in zip(place(subviews, width: bounds.width), subviews) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
