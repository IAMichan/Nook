import Foundation

// A page an agent shows inline in its session's timeline (`render_page` on the bridge): a chart, a diagram, a mock-up.
// Kept as a file with the session and drawn by `RenderedPageRow` in the same sandbox as an MCP app's page, but with
// nothing to talk to: no network, no messages to Nook, no forms, popups or navigation, at a fixed, capped height. The
// page is untrusted, like every tool output. Foundation only, so the rules are tested here (`RenderedPageTests`).

enum RenderedPage {
    /// The event's `tool`: what marks a `.page` event as one of these.
    static let tool = "render_page"
    static let maxHTMLBytes = 512 * 1024
    static let maxTitleLength = 120
    static let defaultHeight = 360.0
    static let minHeight = 80.0
    static let maxHeight = 1200.0

    struct Request: Equatable, Sendable {
        var html: String
        var title: String
        var height: Double
    }

    static func parse(_ arguments: [String: Any]) -> Result<Request, BridgeArgumentError> {
        guard let html = arguments["html"] as? String, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(BridgeArgumentError("Give the page as html: a complete HTML document or fragment."))
        }
        guard html.utf8.count <= maxHTMLBytes else {
            return .failure(BridgeArgumentError("The page is too large (at most \(maxHTMLBytes / 1024) KB). Inline less data, or draw it with fewer elements."))
        }
        let title = BridgeArgs.string(arguments["title"]).map { String($0.components(separatedBy: .newlines).joined(separator: " ").prefix(maxTitleLength)) }
        return .success(Request(html: html, title: title ?? "Page", height: clamp(BridgeArgs.int(arguments["height"]).map(Double.init))))
    }

    static func clamp(_ height: Double?) -> Double {
        guard let height, height.isFinite else { return defaultHeight }
        return min(maxHeight, max(minHeight, height)).rounded()
    }

    /// Where a session's pages are kept: one folder per session, one file per page.
    static func file(in base: URL, run: UUID, page: UUID) -> URL {
        base.appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent(run.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(page.uuidString.lowercased() + ".html")
    }

    /// The timeline's record of a page: its title, the file it is kept in and its height.
    static func event(id: UUID = UUID(), title: String, file: String, height: Double) -> RunEvent {
        RunEvent(kind: .page, text: title, tool: tool, detail: file, output: String(Int(clamp(height))), id: id)
    }

    static func height(of event: RunEvent) -> Double { clamp(event.output.flatMap(Double.init)) }

    /// A page file of this session's own folder under `base`, never a path elsewhere: an event read back from disk is not
    /// trusted to point anywhere else.
    static func isOwnFile(_ path: String, base: URL) -> Bool {
        let folder = base.appendingPathComponent("pages", isDirectory: true).standardizedFileURL.path + "/"
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        return file.hasPrefix(folder) && file.hasSuffix(".html")
    }

    /// What the web view loads: a static page around a sandboxed frame (`allow-scripts` only, so an opaque origin with
    /// no forms, popups, top navigation or storage), holding the page under the MCP app policy without any declared
    /// origin (`McpApp.prepared`): nothing loads or connects anywhere. The outer page has no script and no handler.
    static func hostPage(_ html: String) -> String {
        let inner = McpApp.prepared(html, csp: nil)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><iframe sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="\(inner)"></iframe></body></html>
        """
    }
}
