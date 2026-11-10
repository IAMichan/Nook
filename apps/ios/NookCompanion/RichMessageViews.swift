import Photos
import SwiftUI
import WebKit

/// A message's text with its diagrams and math drawn, as on the Mac (`MessageSegments`). A message without any is the
/// same `Text` as before and costs nothing extra; only the parts that need it get a web view, with Mermaid and KaTeX from
/// the app itself (no network). Touch and hold a diagram or formula to save it to Photos.
struct RichMessageText: View {
    let text: String
    var color: Color = Theme.textStrong

    var body: some View {
        if MessageSegments.mayBeRich(text) {
            let segments = MessageSegments.split(text)
            if segments.contains(where: \.isRich) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if case .text(let prose) = segment {
                            plain(prose.trimmingCharacters(in: .newlines))
                        } else {
                            RichSegmentView(segment: segment)
                        }
                    }
                }
            } else {
                plain(text)
            }
        } else {
            plain(text)
        }
    }

    private func plain(_ text: String) -> some View {
        Markdown.text(text)
            .font(Theme.TextStyle.body)
            .foregroundStyle(color)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// One diagram or piece of math, in a web view as tall as what it draws.
private struct RichSegmentView: View {
    let segment: MessageSegment
    @StateObject private var page = RichPageModel()
    @State private var saved: String?

    var body: some View {
        RichWebView(segment: segment, page: page)
            .frame(height: max(page.height, 24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button { Task { saved = await page.saveToPhotos() } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                if let source = source {
                    MessageCopyButton(text: source)
                }
            }
            .alert(saved ?? "", isPresented: Binding(get: { saved != nil }, set: { if !$0 { saved = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(source.map { Text($0) } ?? Text("Diagram"))
    }

    private var source: String? {
        switch segment {
        case .mermaid(let code): return code
        case .math(let tex): return tex
        case .inlineMath(let text): return text
        case .text: return nil
        }
    }
}

/// The web view's height as the page reports it, and the picture of it to save.
@MainActor
final class RichPageModel: ObservableObject {
    @Published var height: CGFloat = 0
    weak var webView: WKWebView?

    /// A picture of what the page drew, on the app's own background, saved to Photos with add-only access. Returns what to
    /// tell the user.
    func saveToPhotos() async -> String {
        guard let webView else { return String(localized: "Nothing to save yet.") }
        let shot: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        guard let shot else { return String(localized: "Could not make a picture of it.") }
        let picture = UIGraphicsImageRenderer(size: shot.size).image { context in
            UIColor(Theme.canvas).setFill()
            context.fill(CGRect(origin: .zero, size: shot.size))
            shot.draw(at: .zero)
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return String(localized: "Allow Nook Companion to add photos in Settings to save it.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: picture) }
            Haptics.tap()
            return String(localized: "Saved to Photos.")
        } catch {
            return String(localized: "Could not save it: \(error.localizedDescription)")
        }
    }
}

/// The scripts and styles that ship with the app (`Resources/mermaid`, `Resources/katex`, shared with the Mac), read once.
enum RichScripts {
    static let mermaid: String? = read("mermaid.min", "js", in: "mermaid")
    static let katex: String? = read("katex.min", "js", in: "katex")
    static let katexCSS: String = read("katex.min", "css", in: "katex") ?? ""
    /// The folder the KaTeX fonts are found from (`url(fonts/…)` in its style).
    static let katexFolder: URL? = Bundle.main.url(forResource: "katex", withExtension: nil)

    private static func read(_ name: String, _ ext: String, in folder: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

private struct RichWebView: UIViewRepresentable {
    let segment: MessageSegment
    let page: RichPageModel

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "size")
        let mermaid: Bool
        if case .mermaid = segment { mermaid = true } else { mermaid = false }
        if let script = mermaid ? RichScripts.mermaid : RichScripts.katex {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController = controller
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.navigationDelegate = context.coordinator
        page.webView = view
        context.coordinator.load(segment, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.load(segment, in: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "size")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let page: RichPageModel
        private var loaded: MessageSegment?

        init(page: RichPageModel) { self.page = page }

        func load(_ segment: MessageSegment, in view: WKWebView) {
            guard segment != loaded else { return }
            loaded = segment
            let mermaid: Bool
            if case .mermaid = segment { mermaid = true } else { mermaid = false }
            guard let html = RichPage.html(segment, css: mermaid ? "" : RichScripts.katexCSS) else { return }
            view.loadHTMLString(html, baseURL: mermaid ? nil : RichScripts.katexFolder)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double ?? (message.body as? Int).map(Double.init) else { return }
            let height = CGFloat(min(max(value, 0), 4_000))
            Task { @MainActor in if abs(self.page.height - height) > 0.5 { self.page.height = height } }
        }

        /// Nothing in a message may navigate: a link in a diagram stays put.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other ? .allow : .cancel
        }
    }
}
