import Foundation

// What a file in the side panel is, and so how it is shown: as the thing it is (a page, a picture, a diagram, a
// document) with a Preview / Code toggle, or as code. Foundation only, tested in `SidePanelCoreTests`.

enum ArtifactKind: String, Equatable, Sendable, CaseIterable {
    case html, svg, mermaid, markdown, notebook, image, pdf, code

    /// The kind of a file by its extension; anything that is not a known document is code (or plain text).
    static func detect(path: String) -> ArtifactKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm", "xhtml": return .html
        case "svg": return .svg
        case "mmd", "mermaid": return .mermaid
        case "md", "markdown", "mdx": return .markdown
        case "ipynb": return .notebook
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns": return .image
        case "pdf": return .pdf
        default: return .code
        }
    }

    /// Whether the file can be shown as more than its text: a page, a picture, a diagram, a rendered document.
    var hasPreview: Bool { self != .code }

    /// Whether the file is text that can be read, copied and diffed as code (a picture or a PDF is not).
    var isText: Bool { self != .image && self != .pdf }

    /// Whether the file is drawn by a web view in Nook's sandbox (a page or a vector picture), where it never reaches the
    /// network and cannot open a window.
    var rendersInSandbox: Bool { self == .html || self == .svg }

    /// What the page that shows this kind of file around its text is: SVG sits in the middle of a page, HTML is the page.
    func sandboxPage(for text: String) -> String {
        guard self == .svg else { return text }
        return "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;height:100%;background:transparent}"
            + "body{display:flex;align-items:center;justify-content:center}svg{max-width:100%;max-height:100%}</style></head><body>"
            + text + "</body></html>"
    }

    /// The type the Save panel and "Open in browser" use.
    var mimeType: String {
        switch self {
        case .html: return "text/html"
        case .svg: return "image/svg+xml"
        case .markdown: return "text/markdown"
        case .pdf: return "application/pdf"
        case .image: return "image/*"
        case .mermaid, .notebook, .code: return "text/plain"
        }
    }

    /// Opens on its preview, not its code, when it was made for you to look at: a page Nook keeps for an agent's
    /// answer. Any other file opens on its code, and the Preview toggle is one click away.
    func opensOnPreview(ownPage: Bool) -> Bool {
        switch self {
        case .html, .svg: return ownPage
        case .image, .pdf: return true
        case .mermaid, .markdown, .notebook: return true
        case .code: return false
        }
    }
}
