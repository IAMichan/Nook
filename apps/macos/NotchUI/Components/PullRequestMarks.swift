import AppKit
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
/// The picture comes from `GitHubAvatarStore`, read in the first frame when it is in already: a lazy stack builds its
/// rows again as they scroll back, and with `AsyncImage` each one loaded and flickered once more.
struct GitHubAvatar: View {
    let login: String
    var size: CGFloat = 16
    @State private var loaded: NSImage?

    private var url: URL? {
        guard !login.isEmpty, !login.hasSuffix("[bot]"),
              let name = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(name)?s=\(Int(size * 2))")
    }

    var body: some View {
        let source = url
        let image = source.flatMap { GitHubAvatarStore.shared.cached($0) } ?? loaded
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ChatPersonBadge(name: login, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: source) {
            guard let source, GitHubAvatarStore.shared.cached(source) == nil else { return }
            loaded = nil
            loaded = await GitHubAvatarStore.shared.image(for: source)
        }
    }
}

/// GitHub pictures already read, shared by every `GitHubAvatar`: each is asked for once however many rows show it at
/// the same time, and read and decoded off the main thread. `NSCache` drops pictures under memory pressure.
final class GitHubAvatarStore: @unchecked Sendable {
    static let shared = GitHubAvatarStore()

    private let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private let lock = NSLock()
    private var loading: [URL: Task<Void, Never>] = [:]
    /// Pictures GitHub said it does not have, so a row does not ask again each time it is built.
    private var missing: Set<URL> = []

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        lock.lock()
        if missing.contains(url) {
            lock.unlock()
            return nil
        }
        let task: Task<Void, Never>
        if let running = loading[url] {
            task = running
        } else {
            task = Task.detached(priority: .utility) { [self] in await self.read(url) }
            loading[url] = task
        }
        lock.unlock()
        await task.value
        return cached(url)
    }

    private func read(_ url: URL) async {
        let answer = try? await URLSession.shared.data(from: url)
        let found = answer.map { ($0.1 as? HTTPURLResponse)?.statusCode ?? 200 } == 200
        if found, let data = answer?.0, let image = NSImage(data: data) {
            // Decoded here, so the first draw on the main thread does not have to.
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            cache.setObject(image, forKey: url as NSURL)
        }
        lock.lock()
        loading[url] = nil
        // Only a real answer without a picture; a failed request (offline) is asked again later.
        if answer != nil, !found { missing.insert(url) }
        lock.unlock()
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
