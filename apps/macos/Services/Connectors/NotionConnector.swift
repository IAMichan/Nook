import SwiftUI
import os

@MainActor
final class NotionConnector: TokenCloudConnector {
    let id = "notion"
    let title = "Notion"
    let symbol = "doc.text"
    let accent = Color(hex: 0xD9D4C7)
    let refreshInterval: TimeInterval = 300
    @Published var status = ConnectorStatus()

    static let tokenAccount = "connector.notion.token"
    static var fields: [ConnectorField] {
        [ConnectorField(account: NotionConnector.tokenAccount, label: tr("connect.field.token"), placeholder: "ntn_… / secret_…", secret: true)]
    }
    static var helpText: String { tr("connect.notion.help") }
    static let signupURL = URL(string: "https://www.notion.so/profile/integrations")

    private struct Page {
        let id: String
        let title: String
        let edited: Date?
        let url: URL?
    }

    private var pages: [Page] = []
    private var loaded = false

    static var secretAccounts: [String] { [NotionConnector.tokenAccount] }

    func fetchSnapshot(secrets: [String]) async throws {
        apply(try await search(token: secrets[0], query: nil, count: 8))
    }

    func clearSnapshot() {
        pages = []
        loaded = false
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded, !pages.isEmpty else { return [] }
        let parts = pages.prefix(5).map { p -> String in
            var part = "'\(CloudHelp.short(p.title, 50))'"
            if let edited = p.edited { part += " (\(NookDates.ago(edited)))" }
            return part
        }
        return ["Notion, recently edited: " + parts.joined(separator: ", ")]
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "notion_search",
                description: "Searches Notion pages shared with Nook, most recently edited first. Without a search term, returns recently edited pages with links.",
                schema: CloudHelp.schema([
                    "query": ["type": "string", "description": "Search term in page title. Optional."]
                ]),
                kind: .read,
                summarize: { _ in "Read Notion" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("Notion") }
                    let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return try await self.overview(query: query)
                }
            ),
            ToolSpec(
                name: "notion_read_page",
                description: "Reads the text of a single Notion page (headings, paragraphs, lists, to-dos, quotes, code). Provide the ID or link from notion_search. Use this to actually read a document before summarizing or comparing it.",
                schema: ["type": "object", "properties": ["page": ["type": "string", "description": "Page ID or link."]], "required": ["page"]],
                kind: .read,
                summarize: { _ in "Read Notion page" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("Notion") }
                    return try await self.readPage((input["page"] as? String) ?? "")
                }
            )
        ]
    }

    /// The ID from an ID or link: the trailing 32 hex characters (with or without hyphens).
    nonisolated static func pageID(_ raw: String) -> String? {
        let hex = raw.lowercased().replacingOccurrences(of: "-", with: "")
        guard let range = hex.range(of: #"[0-9a-f]{32}(?![0-9a-f])"#, options: [.regularExpression, .backwards]) else { return nil }
        let id = String(hex[range])
        let parts = [id.prefix(8), id.dropFirst(8).prefix(4), id.dropFirst(12).prefix(4), id.dropFirst(16).prefix(4), id.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    private func readPage(_ raw: String) async throws -> String {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(NotionConnector.tokenAccount) else {
            throw CloudHelp.notSetUp("Notion")
        }
        guard let pageID = Self.pageID(raw) else { throw NookError("Invalid Notion ID or link: \(raw)") }
        let headers = ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28"]
        let page = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url("https://api.notion.com/v1/pages/\(pageID)"), headers: headers))
        let info = parse(page)
        var lines: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            var query = [("page_size", "100")]
            if let cursor { query.append(("start_cursor", cursor)) }
            let root = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url("https://api.notion.com/v1/blocks/\(pageID)", "/children", query: query), headers: headers))
            for block in CloudHelp.list(root["results"]) {
                if let line = blockText(block) { lines.append(line) }
            }
            cursor = (root["has_more"] as? Bool) == true ? root["next_cursor"] as? String : nil
            pages += 1
        } while cursor != nil && pages < 5
        var text = lines.joined(separator: "\n")
        if text.count > 15_000 { text = String(text.prefix(15_000)) + "\n… (truncated)" }
        var out = ["\(info?.title ?? "Notion page")" + (info?.edited.map { " · edited \(NookDates.short($0))" } ?? ""), ""]
        out.append(text.isEmpty ? "(No text on this page, or only unsupported blocks such as databases and images.)" : text)
        out.append(ReferenceParser.line(title: info?.title ?? "Notion page", url: info?.url?.absoluteString,
                                        detail: info?.edited.map { "edited \(NookDates.short($0))" } ?? ""))
        return out.joined(separator: "\n")
    }

    private func blockText(_ block: [String: Any]) -> String? {
        guard let type = block["type"] as? String else { return nil }
        let content = CloudHelp.object(block[type])
        guard let text = plainText(content["rich_text"]) else {
            if type == "child_page", let title = content["title"] as? String { return "[subpage] \(title)" }
            return nil
        }
        switch type {
        case "heading_1": return "# " + text
        case "heading_2": return "## " + text
        case "heading_3": return "### " + text
        case "bulleted_list_item": return "- " + text
        case "numbered_list_item": return "1. " + text
        case "to_do": return ((content["checked"] as? Bool) == true ? "- [x] " : "- [ ] ") + text
        case "quote", "callout": return "> " + text
        case "code": return "```\n" + text + "\n```"
        default: return text
        }
    }

    private func search(token: String, query: String?, count: Int) async throws -> [Page] {
        var body: [String: Any] = [
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "filter": ["property": "object", "value": "page"],
            "page_size": count
        ]
        if let query = query, !query.isEmpty { body["query"] = query }
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = try CloudHelp.url("https://api.notion.com/v1/search")
        let raw = try await ConnectorHTTP.json(url, headers: [
            "Authorization": "Bearer \(token)",
            "Notion-Version": "2022-06-28"
        ], method: "POST", body: data)
        return CloudHelp.list(CloudHelp.object(raw)["results"]).compactMap { parse($0) }
    }

    private func parse(_ obj: [String: Any]) -> Page? {
        guard let id = obj["id"] as? String else { return nil }
        var title = ""
        // Databases have "title" at root; pages have a property of type "title".
        if let text = plainText(obj["title"]) { title = text }
        if title.isEmpty {
            for (_, value) in CloudHelp.object(obj["properties"]) {
                let property = CloudHelp.object(value)
                if (property["type"] as? String) == "title", let text = plainText(property["title"]) {
                    title = text
                    break
                }
            }
        }
        return Page(
            id: id,
            title: title.isEmpty ? "Untitled" : title,
            edited: CloudHelp.date(obj["last_edited_time"]),
            url: CloudHelp.link(obj["url"] as? String)
        )
    }

    private func plainText(_ value: Any?) -> String? {
        let text = CloudHelp.list(value).compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    private func apply(_ list: [Page]) {
        pages = list
        loaded = true
        var detail = ""
        if let first = list.first {
            detail = "Latest: \(CloudHelp.short(first.title, 40))"
            if let edited = first.edited { detail += " · \(NookDates.ago(edited))" }
        }
        let items = list.map { p in
            ConnectorItem(id: p.id, title: p.title,
                          subtitle: p.edited.map { "edited \(NookDates.ago($0))" } ?? "",
                          tone: .neutral, url: p.url)
        }
        status = ConnectorStatus(state: .ok,
                                 headline: list.isEmpty ? tr("connect.notion.noPages") : tr("connect.notion.recentlyEdited", list.count),
                                 detail: detail, items: items, updated: Date(), needsAttention: false)
    }

    private func overview(query: String?) async throws -> String {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(NotionConnector.tokenAccount) else {
            throw CloudHelp.notSetUp("Notion")
        }
        let hasQuery = !(query ?? "").isEmpty
        let list = try await search(token: token, query: query, count: 20)
        if !hasQuery { apply(Array(list.prefix(8))) }
        if list.isEmpty {
            return hasQuery ? "No Notion pages found for '\(query ?? "")'." : "No Notion pages shared with Nook."
        }
        let lines = list.map { p -> String in
            var line = "- \(p.title) (id \(p.id))"
            if let edited = p.edited { line += " · edited \(NookDates.short(edited))" }
            return line
        }
        let refs = list.prefix(10).map { p in
            ReferenceParser.line(title: p.title, url: p.url?.absoluteString, detail: p.edited.map { "edited \(NookDates.short($0))" } ?? "")
        }
        return (lines + refs).joined(separator: "\n")
    }
}
