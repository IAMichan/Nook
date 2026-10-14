import SwiftUI
import AppKit

/// Haalt het icoon (favicon) van de dienst achter een koppeling op, van de dienst zelf, en bewaart het op je Mac.
/// Er gaat alleen een verzoek naar het domein dat jij zelf hebt ingesteld.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var revision = 0
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var missed: Set<String> = []

    private let directory: URL = {
        let dir = NookPaths.supportDirectory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    private static func valid(_ domain: String) -> Bool {
        domain.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil && domain.contains(".")
    }

    /// Het icoon als het er al is; anders begint het ophalen en komt het zo via `revision`.
    func image(for domain: String) -> NSImage? {
        let key = domain.lowercased()
        guard Self.valid(key) else { return nil }
        if let image = images[key] { return image }
        let file = directory.appendingPathComponent(key + ".icon")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[key] = image
            return image
        }
        load(key, to: file)
        return nil
    }

    private func load(_ key: String, to file: URL) {
        guard !loading.contains(key), !missed.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            let candidates = ["https://\(key)/apple-touch-icon.png", "https://\(key)/favicon.ico", "https://www.\(key)/favicon.ico"]
            var found: (Data, NSImage)?
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
                try? data.write(to: file, options: .atomic)
                self.images[key] = image
                self.revision += 1
            } else {
                self.missed.insert(key)
            }
        }
    }
}

/// Het icoon van een dienst, of een systeemsymbool zolang dat er nog niet is.
struct SiteIcon: View {
    let domain: String?
    let fallback: String
    var tint: Color = .secondary
    var size: CGFloat = 16
    @ObservedObject private var store = FaviconStore.shared

    var body: some View {
        if let domain, let image = store.image(for: domain) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
        }
    }
}
