import SwiftUI
import AppKit
import Combine

/// Fetches the service icon (favicon) directly from the connected service and caches it on your Mac.
/// Only contacts the specific domain you configured.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var revision = 0
    /// The domain whose icon just came in, so a `SiteIcon` redraws only for its own domain and not for every one.
    let arrived = PassthroughSubject<String, Never>()
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var missed: Set<String> = []

    private let directory: URL = {
        let dir = NookPaths.supportDirectory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    private static let domainCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// Letters, digits, dots and dashes, starting and ending with a letter or digit. Checked by hand and not with a
    /// regex: view bodies ask it on every draw.
    private static func valid(_ domain: String) -> Bool {
        guard let first = domain.first, let last = domain.last, domain.contains(".") else { return false }
        return !".-".contains(first) && !".-".contains(last) && domain.allSatisfy { domainCharacters.contains($0) }
    }

    /// The icon if already cached; otherwise triggers a fetch and updates via `revision`.
    func image(for domain: String) -> NSImage? {
        let key = domain.lowercased()
        guard Self.valid(key) else { return nil }
        if let image = images[key] { return image }
        // Called from view bodies: a domain without an icon must not hit the disk on every redraw.
        guard !missed.contains(key), !loading.contains(key) else { return nil }
        load(key, to: directory.appendingPathComponent(key + ".icon"))
        return nil
    }

    private func load(_ key: String, to file: URL) {
        guard !loading.contains(key), !missed.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            // The copy on disk first, read off the main thread: this starts from a view's first draw.
            let kept = await Task.detached(priority: .utility) { try? Data(contentsOf: file) }.value
            let onDisk = kept.flatMap(NSImage.init(data:))
            var found: (Data, NSImage)?
            if let kept, let onDisk { found = (kept, onDisk) }
            let candidates = found != nil ? [] : ["https://\(key)/apple-touch-icon.png", "https://\(key)/favicon.ico", "https://www.\(key)/favicon.ico"]
            for candidate in candidates {
                guard let url = URL(string: candidate) else { continue }
                guard let (data, response) = try? await ConnectorHTTP.session.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count > 80, data.count < 600_000,
                      let image = NSImage(data: data), image.size.width > 0 else { continue }
                found = (data, image)
                break
            }
            guard let self else { return }
            self.loading.remove(key)
            if let (data, image) = found {
                if onDisk == nil { try? data.write(to: file, options: .atomic) }
                self.images[key] = image
                self.revision += 1
                self.arrived.send(key)
            } else {
                self.missed.insert(key)
            }
        }
    }
}

/// The service icon, or a system symbol fallback while loading. With `source`, the icon of the Mac app that source
/// reads (Calendar, Mail, WhatsApp…) comes first, then the service's own website.
struct SiteIcon: View {
    let domain: String?
    let fallback: String
    var tint: Color = .secondary
    var size: CGFloat = 16
    var source: String? = nil
    /// The icon that came in after the first draw. Not `@ObservedObject` on the store: that redrew every icon in Nook
    /// whenever any one favicon arrived.
    @State private var arrived: (key: String, image: NSImage)?

    @MainActor private var store: FaviconStore { .shared }
    private var resolvedDomain: String? { domain ?? source.flatMap(SourceBrand.domain(for:)) }

    var body: some View {
        icon
            .onReceive(store.arrived) { key in
                guard let domain = resolvedDomain, key == domain.lowercased(),
                      let image = store.image(for: domain) else { return }
                arrived = (key, image)
            }
    }

    @MainActor private func favicon(for domain: String) -> NSImage? {
        if let arrived, arrived.key == domain.lowercased() { return arrived.image }
        return store.image(for: domain)
    }

    @MainActor @ViewBuilder
    private var icon: some View {
        if let source, let app = SourceBrand.appIcon(for: source, side: size * 1.15) {
            // App icons carry their own shape and a little margin: draw them a touch larger than a favicon.
            Image(nsImage: app)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 1.15, height: size * 1.15)
                .frame(width: size, height: size)
        } else if let domain = resolvedDomain, let image = favicon(for: domain) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: fallback)
                .font(NookTheme.font(size * 0.8, .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}
