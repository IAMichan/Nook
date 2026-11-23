import AppKit
import SwiftUI
import WebKit

/// The files you download in Nook's browser. They go to the Downloads folder (`BrowserDownloadName`); while there are
/// any, a button in the browser's toolbar lists them with their progress, and a finished one opens with a click.
@MainActor
final class BrowserDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = BrowserDownloads()

    struct Item: Identifiable, Equatable {
        enum State: Equatable { case running, finished, failed, cancelled }
        let id: UUID
        var name: String
        var file: URL?
        var fraction: Double?
        var state: State
    }

    @Published private(set) var items: [Item] = []
    private var downloads: [ObjectIdentifier: (id: UUID, download: WKDownload, watch: NSKeyValueObservation)] = [:]

    var running: Bool { items.contains { $0.state == .running } }

    /// How a page's answer is shown: a file the browser cannot show, or one the site sends as an attachment, downloads.
    static func policy(for response: WKNavigationResponse) -> WKNavigationResponsePolicy {
        if !response.canShowMIMEType { return .download }
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    /// A download started in a tab or a page's window: from here on it is followed here.
    func track(_ download: WKDownload) {
        let id = UUID()
        download.delegate = self
        let name = download.originalRequest?.url?.lastPathComponent ?? ""
        items.insert(Item(id: id, name: name, file: nil, fraction: nil, state: .running), at: 0)
        let watch = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
            Task { @MainActor in self?.update(id) { $0.fraction = fraction } }
        }
        downloads[ObjectIdentifier(download)] = (id, download, watch)
    }

    func cancel(_ id: UUID) {
        guard let entry = downloads.values.first(where: { $0.id == id }) else { return }
        entry.download.cancel { _ in }
        finish(entry.download, as: .cancelled)
    }

    func open(_ item: Item) {
        guard let file = item.file else { return }
        NSWorkspace.shared.open(file)
    }

    func reveal(_ item: Item) {
        guard let file = item.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func openFolder() {
        if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Takes the finished, failed and stopped downloads off the list; the files stay.
    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let file = BrowserDownloadName.destination(for: suggestedFilename, in: folder) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if let id = downloads[ObjectIdentifier(download)]?.id {
            update(id) {
                $0.name = file.lastPathComponent
                $0.file = file
            }
        }
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let file = downloads[ObjectIdentifier(download)].flatMap({ entry in items.first { $0.id == entry.id }?.file }) {
            // The Downloads stack in the Dock bounces, as it does for Safari's downloads.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        finish(download, as: .finished)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        finish(download, as: cancelled ? .cancelled : .failed)
    }

    private func finish(_ download: WKDownload, as state: Item.State) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.watch.invalidate()
        update(entry.id) {
            $0.state = state
            if state == .finished { $0.fraction = 1 }
        }
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

/// The downloads button in the browser's toolbar: only there once you downloaded something. Its menu lists the
/// downloads, newest first.
struct BrowserDownloadsButton: View {
    @ObservedObject private var downloads = BrowserDownloads.shared
    @State private var hovering = false

    var body: some View {
        if !downloads.items.isEmpty {
            ComposerDropdown(width: 320) {
                Image(icon: downloads.running ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(NookTheme.font(11, .medium))
                    .foregroundStyle(downloads.running ? NookTheme.iris : hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .roundedBackground(hovering ? WS.subtle : Color.clear, radius: NookTheme.Radius.control)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
                    .nookTip(tr("browser.downloads.title"))
                    .accessibilityLabel(tr("browser.downloads.title"))
            } content: {
                DropdownHeader(title: tr("browser.downloads.title"))
                ForEach(downloads.items) { item in
                    BrowserDownloadRow(item: item)
                }
                DropdownDivider()
                DropdownRow(symbol: "folder", title: tr("browser.downloads.openFolder")) { downloads.openFolder() }
                if downloads.items.contains(where: { $0.state != .running }) {
                    DropdownRow(symbol: "xmark.circle", title: tr("browser.downloads.clear"), staysOpen: true) {
                        downloads.clearFinished()
                    }
                }
            }
        }
    }
}

/// One download: its name and how far it is. A click opens a finished file; the button at the end stops a running
/// download or shows a finished one in the Finder.
private struct BrowserDownloadRow: View {
    let item: BrowserDownloads.Item
    @Environment(\.closeDropdown) private var close
    @State private var hovering = false

    private var status: String {
        switch item.state {
        case .running:
            return item.fraction.map { tr("browser.downloads.progress", Int(($0 * 100).rounded())) } ?? tr("browser.downloads.running")
        case .finished: return tr("browser.downloads.finished")
        case .failed: return tr("browser.downloads.failed")
        case .cancelled: return tr("browser.downloads.cancelled")
        }
    }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Button {
                guard item.state == .finished else { return }
                close()
                BrowserDownloads.shared.open(item)
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: item.state == .failed ? "exclamationmark.triangle" : "doc")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(item.state == .failed ? NookTheme.coral : NookTheme.textTertiary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: item.name.isEmpty ? tr("browser.downloads.untitled") : item.name)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(item.state == .finished || item.state == .running ? NookTheme.paper : NookTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(status)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    Spacer(minLength: NookTheme.Spacing.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            if item.state == .running {
                ToolbarIconButton("xmark", tr("browser.downloads.stop"), height: 22, width: 22) {
                    BrowserDownloads.shared.cancel(item.id)
                }
            } else if item.state == .finished {
                ToolbarIconButton("magnifyingglass", tr("browser.downloads.reveal"), height: 22, width: 22) {
                    close()
                    BrowserDownloads.shared.reveal(item)
                }
            }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, NookTheme.Spacing.xs)
        .frame(minHeight: 36)
        .roundedBackground(hovering ? DropdownStyle.hover : .clear, radius: NookTheme.Radius.chip)
        .onHover { hovering = $0 }
    }
}
