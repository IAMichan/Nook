import Foundation

// Interactive results from MCP servers (MCP-UI / MCP Apps): a tool result can carry
// a `ui://` resource, an HTML page or a link, that is meant to be shown rather than read. The parsers keep it in the
// tool's output as a fenced block; the timeline shows it in a sandboxed web view. Foundation only, so tests can use it.
enum McpUI {
    static let fence = "```mcp-ui"

    static let appFence = "```mcp-app"

    struct Resource: Equatable, Sendable {
        var uri: String
        /// The page itself (text/html), or
        var html: String?
        /// a page to open elsewhere (text/uri-list), or
        var link: URL?
        /// an app Nook saved (from Codex), with its page in a file.
        var app: McpApp.Reference? = nil
    }

    /// The tool output for an app Nook saved: its reference, then the tool's own result text.
    static func encode(app: McpApp.Reference, resultText: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(app)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return appFence + "\n" + json + "\n```" + (resultText.isEmpty ? "" : "\n" + resultText)
    }

    /// A tool result's content block as text for the output: the fenced resource, or nil when it is not a UI resource.
    static func encode(_ block: [String: Any]) -> String? {
        guard (block["type"] as? String) == "resource", let resource = block["resource"] as? [String: Any],
              let uri = resource["uri"] as? String, uri.hasPrefix("ui://") else { return nil }
        let mime = ((resource["mimeType"] as? String) ?? "").lowercased()
        var text = resource["text"] as? String
        if text == nil, let blob = resource["blob"] as? String, let data = Data(base64Encoded: blob) {
            text = String(data: data, encoding: .utf8)
        }
        guard let text, !text.isEmpty else { return nil }
        if mime.hasPrefix("text/html") {
            return fence + " " + uri + "\n" + text + "\n```"
        }
        if mime.hasPrefix("text/uri-list"),
           let first = text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
               .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
           let url = URL(string: first), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return fence + "-link " + uri + "\n" + first + "\n```"
        }
        return nil
    }

    /// The UI resource in a tool's output, if any.
    static func resource(in output: String?) -> Resource? {
        if let output, let start = output.range(of: appFence + "\n") {
            let rest = output[start.upperBound...]
            guard let close = rest.range(of: "\n```"),
                  let app = try? JSONDecoder().decode(McpApp.Reference.self, from: Data(rest[rest.startIndex..<close.lowerBound].utf8)) else { return nil }
            return Resource(uri: app.resourceUri, html: nil, link: nil, app: app)
        }
        guard let output, let start = output.range(of: fence) else { return nil }
        let rest = output[start.upperBound...]
        let isLink = rest.hasPrefix("-link ")
        guard let header = rest.firstIndex(of: "\n") else { return nil }
        let uri = rest[rest.startIndex..<header].replacingOccurrences(of: "-link", with: "").trimmingCharacters(in: .whitespaces)
        let body = rest[rest.index(after: header)...]
        // The last fence closes it (the page may contain fences of its own); a clipped output has none.
        guard let close = body.range(of: "\n```", options: .backwards) else { return nil }
        let content = String(body[body.startIndex..<close.lowerBound])
        if isLink { return URL(string: content).map { Resource(uri: uri, html: nil, link: $0) } }
        return Resource(uri: uri, html: content, link: nil)
    }

    /// The output without the resource block: what is left to read.
    static func stripped(_ output: String) -> String {
        if let start = output.range(of: appFence + "\n"), let close = output[start.upperBound...].range(of: "\n```") {
            return (String(output[..<start.lowerBound]) + output[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = output.range(of: fence),
              let close = output[start.upperBound...].range(of: "\n```", options: .backwards) else { return output }
        let tail = output[close.upperBound...]
        return (String(output[..<start.lowerBound]) + tail).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
