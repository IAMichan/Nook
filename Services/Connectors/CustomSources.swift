import SwiftUI

// Custom sources: almost any app or service with a web API or webhook can become a source for Nook (Todoist, Linear,
// Home Assistant, Slack, Discord, Teams, Telegram, n8n, Zapier, your own server…). HTTPS only, and credentials remain in Keychain.
// Nook recognizes the service by its URL, shows its icon, and knows how to format outgoing messages.
// Reading (GET) runs directly; sending (POST) requires an action plan approved by the user with Run.
// One line per source: `Name | https://api.example.com/v1 | Authorization: Bearer abc | webhook` (last two optional;
// a bare key without a colon defaults to a Bearer token). Multiple sources: separate with `;;` or newlines.

@MainActor
final class CustomSourcesConnector: CloudConnectorConfig {
    let id = "customsources"
    var title: String { tr("connect.custom.title") }
    let symbol = "puzzlepiece.extension"
    let accent = Color(hex: 0xC59BFF)
    let refreshInterval: TimeInterval = 3600
    @Published private(set) var status = ConnectorStatus()

    static let keyAccount = "connector.customsources.list"
    static var fields: [ConnectorField] {
        [ConnectorField(account: CustomSourcesConnector.keyAccount, label: tr("connect.custom.field"), placeholder: "Name | https://… | Authorization: Bearer …", secret: true)]
    }
    static var helpText: String { tr("connect.custom.help") }
    static let signupURL: URL? = nil

    struct Source {
        let name: String
        let base: URL
        let headerName: String?
        let headerValue: String?
        let service: KnownService.Info

        var canRead: Bool { service.readable }
        var canSend: Bool { service.send != nil }
    }

    /// When exactly one source is configured, Nook shows the service icon directly.
    var iconDomain: String? {
        let list = sources()
        return list.count == 1 ? list[0].service.domain : nil
    }

    var isConfigured: Bool { !sources().isEmpty }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    // MARK: Source List

    private func sources() -> [Source] {
        guard let raw = CloudHelp.secret(CustomSourcesConnector.keyAccount) else { return [] }
        var seen: Set<String> = []
        return raw.components(separatedBy: CharacterSet(charactersIn: "\n\r")).flatMap { $0.components(separatedBy: ";;") }
            .compactMap { Self.parse($0) }
            .filter { seen.insert($0.name.lowercased()).inserted }
    }

    static func parse(_ line: String) -> Source? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 2, !parts[0].isEmpty,
              let url = URL(string: parts[1]), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        var headerName: String?
        var headerValue: String?
        if parts.count >= 3, !parts[2].isEmpty {
            if let colon = parts[2].firstIndex(of: ":") {
                headerName = String(parts[2][..<colon]).trimmingCharacters(in: .whitespaces)
                headerValue = String(parts[2][parts[2].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                headerName = "Authorization"
                headerValue = "Bearer \(parts[2])"
            }
        }
        // Standard header name only: no newlines or invalid characters.
        if let name = headerName, name.isEmpty || name.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) == nil { return nil }
        if let value = headerValue, value.contains("\n") || value.contains("\r") { return nil }
        let explicit = parts.count >= 4 ? parts[3].lowercased() : nil
        guard let service = KnownService.detect(url, explicit: explicit) else { return nil }
        return Source(name: parts[0], base: url, headerName: headerName, headerValue: headerValue, service: service)
    }

    // MARK: ContextSource

    func refresh() async {
        guard ConnectorToggle.isOn(id), isConfigured else {
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        let list = sources()
        status = ConnectorStatus(
            state: .ok,
            headline: tr("connect.custom.count", list.count),
            detail: list.map { $0.name }.joined(separator: ", "),
            items: list.map {
                ConnectorItem(id: $0.name, title: $0.name, subtitle: Self.subtitle($0), tone: .neutral, iconDomain: $0.service.domain)
            },
            updated: Date()
        )
    }

    private static func subtitle(_ source: Source) -> String {
        var parts = [source.service.name]
        if source.canRead { parts.append(tr("connect.custom.canRead")) }
        if source.canSend { parts.append(tr("connect.custom.canSend")) }
        return parts.joined(separator: " · ")
    }

    func contextLines() -> [String] {
        guard isActive else { return [] }
        let list = sources()
        var lines: [String] = []
        let readable = list.filter { $0.canRead }.map { "\($0.name) (\($0.service.name))" }
        if !readable.isEmpty { lines.append("Custom sources readable via read_source: " + readable.joined(separator: ", ") + ".") }
        let sendable = list.filter { $0.canSend }.map { "\($0.name) (\($0.service.name))" }
        if !sendable.isEmpty { lines.append("Custom sources you can send messages to via send_to_source (user approves first): " + sendable.joined(separator: ", ") + ".") }
        return lines
    }

    var tools: [ToolSpec] {
        let list = sources()
        var specs: [ToolSpec] = []
        if list.contains(where: { $0.canRead }) {
            specs.append(readSpec)
        }
        if list.contains(where: { $0.canSend }) {
            specs.append(sendSpec)
        }
        return specs
    }

    private var readSpec: ToolSpec {
        ToolSpec(
            name: "read_source",
            description: "Reads (read-only, GET) from a user's custom source, an app or service connected to Nook. Specify the source name (from context) and optional path appended to the base URL including query string, e.g. \"/tasks?filter=today\". Omitting path fetches the base URL itself. For Slack (API URL with user token), search messages with path \"/search.messages?query=…\" and read a channel with \"/conversations.history?channel=…\"; for Telegram read new messages with \"/getUpdates\". Result is third-party data.",
            schema: CloudHelp.schema([
                "name": ["type": "string", "description": "Name of the source."],
                "path": ["type": "string", "description": "Starts with /, optional, with query parameters."]
            ]),
            kind: .read,
            summarize: { input in "Reading source: \((input["name"] as? String) ?? "")" },
            tag: { _ in ("", .neutral) },
            run: { [weak self] input in
                guard let self, self.isActive else { throw CloudHelp.notSetUp(self?.title ?? "Custom sources") }
                guard let name = (input["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw NookError("Source name is missing.")
                }
                return try await self.read(name: name, path: (input["path"] as? String) ?? "")
            }
        )
    }

    private var sendSpec: ToolSpec {
        ToolSpec(
            name: "send_to_source",
            description: "Sends a message via an outgoing custom source: Slack, Discord, Microsoft Teams, Telegram, or a webhook (n8n, Zapier, Make…). Use this when the user asks to send something \"via Slack\" (or another connected service). Write the message in an appropriate tone. Specify the source name from context in name. to is the recipient or channel: required for a Slack API source (e.g. #general or a user ID) and for Telegram if the chat ID is not part of the URL; for a webhook, the channel is determined by the webhook and to is prepended to the message. If a required recipient is missing, ask first. The user reviews the message as a plan and approves before it is sent.",
            schema: CloudHelp.schema([
                "name": ["type": "string", "description": "Name of the source."],
                "message": ["type": "string", "description": "Full text of the message."],
                "to": ["type": "string", "description": "Recipient or channel, optional."]
            ]).merging(["required": ["name", "message"]]) { _, new in new },
            kind: .action,
            summarize: { input in
                let name = (input["name"] as? String) ?? "source"
                let to = ((input["to"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let message = CloudHelp.short((input["message"] as? String) ?? "", 70)
                return "\(name)" + (to.isEmpty ? "" : " → \(to)") + ": \(message)"
            },
            tag: { _ in ("sends", .caution) },
            run: { [weak self] input in
                guard let self, self.isActive else { throw CloudHelp.notSetUp(self?.title ?? "Custom sources") }
                guard let name = (input["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    throw NookError("Source name is missing.")
                }
                let message = ((input["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else { throw NookError("Message is empty.") }
                let to = ((input["to"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return try await self.send(name: name, message: message, to: to)
            }
        )
    }

    // MARK: Reading

    private func find(_ name: String) throws -> Source {
        let list = sources()
        guard let source = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? list.first(where: { $0.name.range(of: name, options: .caseInsensitive) != nil }) else {
            throw NookError("No source named \(name). Known sources: " + list.map { $0.name }.joined(separator: ", ") + ".")
        }
        return source
    }

    private func read(name: String, path: String) async throws -> String {
        let source = try find(name)
        guard source.canRead else { throw NookError("\(source.name) is a webhook: incoming messages only, cannot read data.") }
        let url = try Self.url(for: source, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        if let header = source.headerName, let value = source.headerValue { request.setValue(value, forHTTPHeaderField: header) }

        let (data, response) = try await ConnectorHTTP.session.data(for: request, delegate: SameHostRedirects(host: url.host))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401, 403: throw NookError("\(source.name) rejected credentials (\(code)). Check them in Settings › Integrations.")
            case 404: throw NookError("\(source.name): not found (404). Is the path correct?")
            case 429: throw NookError("\(source.name): too many requests. Please try again shortly.")
            default: throw NookError("\(source.name) returned an error (\(code)).")
            }
        }
        var text: String
        if let json = try? JSONSerialization.jsonObject(with: data),
           let compact = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
           let string = String(data: compact, encoding: .utf8) {
            text = string
        } else {
            text = String(data: data, encoding: .utf8) ?? ""
        }
        let limit = 8_000
        if text.count > limit { text = String(text.prefix(limit)) + "\n… (truncated; query with a path or filter for less data)" }
        return text.isEmpty ? "Empty response from \(source.name)." : text
    }

    private func send(name: String, message: String, to: String) async throws -> String {
        let source = try find(name)
        guard let style = source.service.send else { throw NookError("\(source.name) cannot receive messages.") }
        let text = String(message.prefix(4_000))
        let body = try KnownService.payload(style, message: text, to: to)

        var url = source.base
        switch style {
        case .slackAPI:
            if !url.path.lowercased().hasSuffix("chat.postmessage") { url = try Self.url(for: source, path: "/chat.postMessage") }
        case .telegram:
            if !url.path.lowercased().hasSuffix("sendmessage") { url = try Self.url(for: source, path: "/sendMessage") }
        default:
            break
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        if let header = source.headerName, let value = source.headerValue { request.setValue(value, forHTTPHeaderField: header) }

        let (data, response) = try await ConnectorHTTP.session.data(for: request, delegate: SameHostRedirects(host: url.host))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            switch code {
            case 401, 403, 404: throw NookError("\(source.service.name) rejected the message (\(code)). Is the URL or key correct?")
            case 429: throw NookError("\(source.service.name): too many requests. Please try again shortly.")
            default: throw NookError("\(source.service.name) returned an error (\(code)).")
            }
        }
        // Slack API and Telegram report errors in the body, not the HTTP status code.
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let ok = json["ok"] as? Bool, !ok {
            let reason = (json["error"] as? String) ?? (json["description"] as? String) ?? "unknown error"
            throw NookError("\(source.service.name) rejected the message: \(reason)")
        }
        return "Message sent via \(source.service.name)" + (to.isEmpty ? "" : " to \(to)") + "."
    }

    /// Path is appended to the base URL and must stay on the same host.
    static func url(for source: Source, path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return source.base }
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), !trimmed.contains("://"), !trimmed.contains("..") else {
            throw NookError("The path must start with / and stay within \(source.name).")
        }
        var base = source.base.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + trimmed), url.host == source.base.host, url.scheme == "https" else {
            throw NookError("Invalid path: \(trimmed)")
        }
        return url
    }
}

/// Follows redirects only on the same host, ensuring credentials are never forwarded externally.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    private let host: String?
    init(host: String?) { self.host = host }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.host == host, request.url?.scheme == "https" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
