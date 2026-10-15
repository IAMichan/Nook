import Foundation

/// Web searching and webpage reading for any brain (including Ollama, LM Studio, and the embedded model).
/// Claude via the API additionally has Anthropic's native search tool.
///
/// Safety: read_webpage only opens addresses that have already explicitly appeared (in your prompt, on your screen, in your tabs,
/// or in search results). This prevents text from a webpage from inducing the brain to exfiltrate data to an arbitrary destination.
@MainActor
final class WebTools {
    private var knownURLs: [String] = []
    private var knownSet: Set<String> = []

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Records URLs found in this text so that the brain is permitted to open them.
    func note(_ text: String) {
        guard let detector = Self.detector, !text.isEmpty else { return }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            remember(url.absoluteString)
        }
    }

    private func remember(_ raw: String) {
        let key = Self.normalize(raw)
        guard !key.isEmpty, knownSet.insert(key).inserted else { return }
        knownURLs.append(key)
        if knownURLs.count > 3000 {
            let drop = knownURLs.prefix(1000)
            knownURLs.removeFirst(1000)
            for item in drop { knownSet.remove(item) }
        }
    }

    private static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasPrefix("http://") { text = "https://" + text.dropFirst(7) }
        return text.lowercased()
    }

    func isKnown(_ raw: String) -> Bool {
        knownSet.contains(Self.normalize(raw))
    }

    // MARK: Tools

    /// `includeSearch`: false for Claude via the API, which searches using Anthropic's native search tool.
    func specs(includeSearch: Bool) -> [ToolSpec] {
        var list: [ToolSpec] = []
        if includeSearch {
            list.append(ToolSpec(
                name: "search_web",
                description: "Searches the web (DuckDuckGo) and returns top results with title, URL, and snippet. Use for current info outside the Mac: news, weather, opening hours, prices, results, documentation. Follow up with read_webpage if more detail is needed.",
                schema: ["type": "object", "properties": ["query": ["type": "string", "description": "Search query."]], "required": ["query"]],
                kind: .read,
                summarize: { _ in "Search web" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Search query is missing.") }
                    let results = try await WebTools.search(query)
                    guard !results.isEmpty else { return "No results for \"\(query)\"." }
                    for result in results { self?.remember(result.url) }
                    return results.prefix(8).map { "### \($0.title)\n\($0.url)\n\($0.snippet)" }.joined(separator: "\n\n")
                }
            ))
        }
        list.append(ToolSpec(
            name: "read_webpage",
            description: "Reads the text of a webpage. Only for URLs that have already appeared: in the request, on screen, in browser tabs, or in search results.",
            schema: ["type": "object", "properties": ["url": ["type": "string", "description": "The full address (https://…)."]], "required": ["url"]],
            kind: .read,
            summarize: { _ in "Read webpage" },
            tag: { _ in ("", .neutral) },
            run: { [weak self] input in
                let raw = ((input["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                    throw NookError("Invalid web address.")
                }
                guard self?.isKnown(raw) == true else {
                    throw NookError("This address was not seen in context; look it up first using search_web.")
                }
                return try await WebTools.read(url)
            }
        ))
        return list
    }

    // MARK: Network

    struct SearchResult {
        var title: String
        var url: String
        var snippet: String
    }

    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "nl-NL,nl;q=0.9,en;q=0.8"
        ]
        return URLSession(configuration: configuration)
    }()

    nonisolated static func search(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "kl", value: "nl-nl")]
        guard let url = components?.url else { return [] }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8) else {
            throw NookError("Web search failed. Please try again shortly.")
        }
        return parseResults(html)
    }

    /// DuckDuckGo's HTML page: each result contains a link with class "result__a" and snippet text with class "result__snippet".
    nonisolated static func parseResults(_ html: String) -> [SearchResult] {
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.dotMatchesLineSeparators]),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let links = linkRegex.matches(in: html, range: range)
        let snippets = snippetRegex.matches(in: html, range: range)
        var results: [SearchResult] = []
        for (index, match) in links.enumerated() {
            guard let hrefRange = Range(match.range(at: 1), in: html), let titleRange = Range(match.range(at: 2), in: html) else { continue }
            var href = decodeEntities(String(html[hrefRange]))
            if href.hasPrefix("//") { href = "https:" + href }
            // DuckDuckGo redirect: the actual target URL is in uddg.
            if let redirect = URLComponents(string: href), redirect.host?.contains("duckduckgo.com") == true,
               let target = redirect.queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = target
            }
            guard href.hasPrefix("http"), !href.contains("duckduckgo.com/y.js") else { continue }
            var snippet = ""
            if index < snippets.count, let snippetRange = Range(snippets[index].range(at: 1), in: html) {
                snippet = plain(String(html[snippetRange]))
            }
            results.append(SearchResult(title: plain(String(html[titleRange])), url: href, snippet: snippet))
        }
        return results
    }

    /// Reads a public page. The host is resolved and checked, and so is every redirect (see `NetworkGuard`).
    nonisolated static func read(_ url: URL) async throws -> String {
        let (data, response) = try await NetworkGuard.fetch(url)
        let status = response.statusCode
        guard (200..<300).contains(status) else { throw NookError("Page returned status \(status).") }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard data.count < 4_000_000 else { throw NookError("Page is too large to read.") }
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text = type.contains("html") || raw.contains("<html") ? readable(raw) : raw
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NookError("No readable text found on that page.") }
        return String(trimmed.prefix(14_000))
    }

    /// Converts HTML to readable text: strips scripts, styles, and navigation; places blocks on separate lines.
    nonisolated static func readable(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        text = plain(text)
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text
    }

    nonisolated static func plain(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&nbsp;": " ", "&apos;": "'"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        // Numeric entities, e.g. &#233;
        if let regex = try? NSRegularExpression(pattern: "&#(\\d{2,6});") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 1), in: result),
                      let code = UInt32(result[digits]), let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }

}
