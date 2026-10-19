import Foundation

// MCP Apps (the `io.modelcontextprotocol/ui` extension) hosts them: a tool whose result has a `ui://`
// resource shows that page in the timeline, and the page talks to Nook over JSON-RPC (postMessage) to call the server's
// tools, read its resources, open links, send a message, change its size or go fullscreen. Codex fetches the page and
// runs the tools for Nook (`mcpServer/resource/read`, `mcpServer/tool/call`); a page another agent embedded in its tool
// result (see McpUI) gets everything but the server's tools. Foundation only, so tests can use it.

enum McpApp {
    static let protocolVersion = "2026-01-26"
    static let mimeType = "text/html;profile=mcp-app"
    static let scheme = "ui://"
    static let maxHTMLBytes = 5 * 1024 * 1024
    static let minHeight = 80.0
    static let defaultHeight = 320.0
    static let maxHeight = 2000.0
    static let maxMessageBytes = 256 * 1024
    static let maxPendingRequests = 16
    static let maxContextBytes = 16 * 1024

    /// The origins the page may load from or connect to (its `_meta.ui.csp`).
    struct Csp: Codable, Equatable, Sendable {
        var connectDomains: [String]?
        var resourceDomains: [String]?
        var frameDomains: [String]?
        var baseUriDomains: [String]?
    }

    /// An app in the timeline: where its page is kept and what it came from.
    struct Reference: Codable, Equatable, Sendable {
        /// The page, saved with its Content-Security-Policy (nil: the page is inline in the tool output).
        var file: String?
        /// The MCP server and tool (nil server: the agent offers no way to reach the server again).
        var server: String?
        var tool: String
        var resourceUri: String
        var csp: Csp?
        /// camera, microphone, geolocation, clipboardWrite.
        var permissions: [String]?
        var prefersBorder: Bool?
        /// The tool call it belongs to, as JSON: what the page gets as tool-input and tool-result.
        var arguments: String?
        var result: String?
    }

    // MARK: Reading the server's answer

    private static let domainPattern = try! NSRegularExpression(
        pattern: #"^(?:https?|wss?)://(?:\*\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*(?::\d{1,5})?$"#, options: [.caseInsensitive])

    /// Only scheme-qualified origins (optionally `*.` subdomains) survive, at most 32: anything else could widen or break
    /// the policy.
    static func domains(_ value: Any?) -> [String]? {
        let list = ((value as? [Any]) ?? []).compactMap { $0 as? String }.filter { domain in
            domain.count <= 256 && domainPattern.firstMatch(in: domain, range: NSRange(domain.startIndex..., in: domain)) != nil
        }
        return list.isEmpty ? nil : Array(list.prefix(32))
    }

    static func csp(_ value: Any?) -> Csp? {
        guard let raw = value as? [String: Any] else { return nil }
        let csp = Csp(connectDomains: domains(raw["connectDomains"]), resourceDomains: domains(raw["resourceDomains"]),
                      frameDomains: domains(raw["frameDomains"]), baseUriDomains: domains(raw["baseUriDomains"]))
        return csp == Csp() ? nil : csp
    }

    static func permissions(_ value: Any?) -> [String]? {
        guard let raw = value as? [String: Any] else { return nil }
        let list = ["camera", "microphone", "geolocation", "clipboardWrite"].filter { raw[$0] is [String: Any] }
        return list.isEmpty ? nil : list
    }

    /// `_meta.ui.resourceUri` (or the older `_meta["ui/resourceUri"]`) of a tool or result.
    static func resourceUri(meta: Any?) -> String? {
        guard let meta = meta as? [String: Any] else { return nil }
        let uri = ((meta["ui"] as? [String: Any])?["resourceUri"]) ?? meta["ui/resourceUri"]
        guard let text = uri as? String, text.hasPrefix(scheme) else { return nil }
        return text
    }

    /// The tool's resource URI as Codex reports it on an `mcpToolCall` item.
    static func resourceUri(codexItem item: [String: Any]) -> String? {
        let uri = ((item["mcpAppUi"] as? [String: Any])?["resourceUri"]) ?? item["mcpAppResourceUri"]
            ?? ((item["appContext"] as? [String: Any])?["resourceUri"])
        guard let text = uri as? String, text.hasPrefix(scheme) else { return nil }
        return text
    }

    /// A tool the page may call: the spec hides tools whose `_meta.ui.visibility` leaves out "app".
    static func callableByApp(meta: Any?) -> Bool {
        guard let visibility = ((meta as? [String: Any])?["ui"] as? [String: Any])?["visibility"] as? [Any] else { return true }
        return visibility.contains { ($0 as? String) == "app" }
    }

    struct Document: Equatable {
        var html: String
        var csp: Csp?
        var permissions: [String]?
        var prefersBorder: Bool?
    }

    /// The page in a `resources/read` answer: the entry for this URI with the app mime type, text or base64, at most 5 MB.
    static func document(contents: [Any], uri: String) -> Document? {
        for case let content as [String: Any] in contents {
            if let other = content["uri"] as? String, other != uri { continue }
            let mime = ((content["mimeType"] as? String) ?? "").replacingOccurrences(of: " ", with: "").lowercased()
            guard mime == mimeType else { continue }
            var html: String?
            if let text = content["text"] as? String {
                guard text.utf8.count <= maxHTMLBytes else { return nil }
                html = text
            } else if let blob = content["blob"] as? String {
                guard blob.count <= (maxHTMLBytes + 2) / 3 * 4, let data = Data(base64Encoded: blob) else { return nil }
                html = String(decoding: data, as: UTF8.self)
            }
            guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let ui = ((content["_meta"] as? [String: Any])?["ui"] as? [String: Any]) ?? [:]
            return Document(html: html, csp: csp(ui["csp"]), permissions: permissions(ui["permissions"]),
                            prefersBorder: ui["prefersBorder"] as? Bool)
        }
        return nil
    }

    // MARK: The page as Nook shows it

    /// Undeclared origins stay blocked; nothing may load from Nook itself.
    static func contentSecurityPolicy(_ csp: Csp?) -> String {
        let resources = csp?.resourceDomains?.joined(separator: " ") ?? ""
        func list(_ domains: [String]?, _ fallback: String) -> String {
            guard let domains, !domains.isEmpty else { return fallback }
            return domains.joined(separator: " ")
        }
        return [
            "default-src 'none'",
            "script-src 'unsafe-inline' \(resources)".trimmingCharacters(in: .whitespaces),
            "style-src 'unsafe-inline' \(resources)".trimmingCharacters(in: .whitespaces),
            "img-src data: blob: \(resources)".trimmingCharacters(in: .whitespaces),
            "font-src data: \(resources)".trimmingCharacters(in: .whitespaces),
            "media-src data: blob: \(resources)".trimmingCharacters(in: .whitespaces),
            "connect-src \(list(csp?.connectDomains, "'none'"))",
            "frame-src \(list(csp?.frameDomains, "'none'"))",
            "object-src 'none'",
            "base-uri \(list(csp?.baseUriDomains, "'none'"))",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// The policy as the page's first tag, after a doctype so it stays in standards mode; then a cookie shim (an opaque
    /// page throws on `document.cookie`) and the dark/light scheme from the host context.
    static func prepared(_ html: String, csp: Csp?) -> String {
        let policy = contentSecurityPolicy(csp).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        let head = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + cookieShim + themeBootstrap
        if let doctype = html.range(of: #"^\x{FEFF}?\s*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return String(html[doctype]) + head + html[doctype.upperBound...]
        }
        return "<!doctype html>" + head + html
    }

    private static let cookieShim = #"<script>(function(){try{void document.cookie;}catch(error){if(error&&error.name==="SecurityError"){Object.defineProperty(document,"cookie",{configurable:true,get:function(){return "";},set:function(){}});}}})();</script>"#

    private static let themeBootstrap = """
    <script>(()=>{window.addEventListener("message",(event)=>{if(event.source!==window.parent)return;const m=event.data;\
    if(!m||m.jsonrpc!=="2.0")return;const t=m.method==="ui/notifications/host-context-changed"?m.params?.theme:\
    (m.id!==undefined&&m.method===undefined?m.result?.hostContext?.theme:undefined);\
    if(t==="light"||t==="dark")document.documentElement.style.colorScheme=t;});})();</script>
    """

    /// The iframe's `allow` attribute from the page's permissions.
    static func allowAttribute(_ permissions: [String]?) -> String {
        let names = ["camera": "camera", "microphone": "microphone", "geolocation": "geolocation", "clipboardWrite": "clipboard-write"]
        return (permissions ?? []).compactMap { names[$0] }.joined(separator: "; ")
    }

    static func clampHeight(_ height: Double) -> Double {
        guard height.isFinite else { return defaultHeight }
        return min(maxHeight, max(minHeight, height)).rounded()
    }

    /// A file name the page asked to download, without path characters.
    static func downloadName(uri: String?, name: String?) -> String {
        var raw = name?.trimmingCharacters(in: .whitespaces) ?? ""
        if raw.isEmpty { raw = uri?.split(whereSeparator: { "/?#".contains($0) }).last.map(String.init) ?? "download" }
        let safe = String(raw.map { "\\/:*?\"<>|".contains($0) || ($0.asciiValue ?? 32) < 32 ? "-" : $0 })
        return safe.isEmpty ? "download" : String(safe.prefix(200))
    }

    /// What the page tells the agent for its next turn (`ui/update-model-context`): its text blocks and structured
    /// content as JSON, at most 16 KB. Nil: it cleared it, or sent something else than text.
    static func modelContext(content: [Any]?, structured: [String: Any]?) -> String?? {
        var parts: [String] = []
        for block in content ?? [] {
            guard let block = block as? [String: Any], (block["type"] as? String) == "text", let text = block["text"] as? String else { return nil }
            parts.append(text)
        }
        if let structured, let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= maxContextBytes else { return nil }
        return .some(text.isEmpty ? nil : text)
    }

    /// The contexts apps gave, as one block ahead of a message to an agent that has no field for it (Codex gets them
    /// as `additionalContext` instead). Marked as coming from the app, not from you.
    static func contextPreamble(_ contexts: [(key: String, text: String)]) -> String {
        guard !contexts.isEmpty else { return "" }
        return contexts.map { "<mcp_app_context id=\"\($0.key)\" trust=\"untrusted\">\n\($0.text)\n</mcp_app_context>" }
            .joined(separator: "\n") + "\n\n"
    }

    /// Null fields dropped: Codex reports absent ones as null, which the app SDK rejects.
    static func normalizedToolResult(_ result: [String: Any]) -> [String: Any] {
        var normalized: [String: Any] = ["content": (result["content"] as? [Any]) ?? []]
        if let structured = result["structuredContent"] as? [String: Any] { normalized["structuredContent"] = structured }
        if (result["isError"] as? Bool) == true { normalized["isError"] = true }
        if let meta = result["_meta"] as? [String: Any] { normalized["_meta"] = meta }
        return normalized
    }

    static func json(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ json: String?) -> Any? {
        json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }
}

/// The host side of one app's JSON-RPC conversation. It checks every request and answers;
/// what needs Nook (calling a tool, a confirmation, a window) goes through `actions`.
final class McpAppHost {
    enum DisplayMode: String { case inline, fullscreen }

    struct Actions {
        var post: ([String: Any]) -> Void
        var hostContext: () -> [String: Any]
        /// Results are JSON objects, or an error message.
        var callTool: (_ name: String, _ arguments: [String: Any], _ done: @escaping (Result<[String: Any], Error>) -> Void) -> Void
        var readResource: (_ uri: String, _ done: @escaping (Result<[String: Any], Error>) -> Void) -> Void
        var openLink: (_ url: URL, _ done: @escaping (Result<Void, Error>) -> Void) -> Void
        var sendMessage: (_ text: String, _ done: @escaping (Result<Void, Error>) -> Void) -> Void
        var updateModelContext: (_ text: String?, _ done: @escaping (Result<Void, Error>) -> Void) -> Void
        var requestDisplayMode: (_ mode: DisplayMode, _ done: @escaping (DisplayMode) -> Void) -> Void
        var downloadFiles: (_ files: [Download], _ done: @escaping (Result<Void, Error>) -> Void) -> Void
        var onSizeChanged: (_ width: Double?, _ height: Double?) -> Void
        var onRequestTeardown: () -> Void
    }

    enum Download: Equatable {
        case embedded(name: String, mimeType: String, data: Data)
        case link(name: String, uri: String)
    }

    struct Refusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let reference: McpApp.Reference
    let hostVersion: String
    private let actions: Actions
    private(set) var initialized = false
    private var disposed = false
    private var toolCallSent = false
    private var pending = 0
    private var sentContext: [String: Any]?
    private var appDisplayModes: [String]?
    private var teardownDone: (() -> Void)?

    init(reference: McpApp.Reference, hostVersion: String, actions: Actions) {
        self.reference = reference
        self.hostVersion = hostVersion
        self.actions = actions
    }

    func dispose() { disposed = true }

    /// One message the page posted (its source already checked).
    func receive(_ data: Any) {
        guard !disposed, let message = data as? [String: Any], (message["jsonrpc"] as? String) == "2.0" else { return }
        let id = Self.id(message["id"])
        if (McpApp.json(message)?.utf8.count ?? Int.max) > McpApp.maxMessageBytes {
            if let id, message["method"] is String { fail(id, -32600, "Message too large.") }
            return
        }
        guard let method = message["method"] as? String else {
            if let id, "\(id)" == "nook-teardown" { teardownDone?(); teardownDone = nil }
            return
        }
        let params = (message["params"] as? [String: Any]) ?? [:]
        if let id { request(id, method, params) } else { notification(method, params) }
    }

    /// Asks the page to wrap up before it goes away (`ui/resource-teardown`): done when it answers, or after 2 s.
    func teardown(_ done: @escaping () -> Void) {
        guard !disposed, initialized else { disposed = true; return done() }
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.disposed = true
            done()
        }
        teardownDone = finish
        actions.post(["jsonrpc": "2.0", "id": "nook-teardown", "method": "ui/resource-teardown", "params": [String: Any]()])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    }

    /// The host context changed (size, display mode): only what changed goes to the page.
    func updateHostContext() {
        guard initialized, let sent = sentContext else { return }
        let next = actions.hostContext()
        var changes: [String: Any] = [:]
        for (key, value) in next where McpApp.json(["v": value]) != sent[key].flatMap({ McpApp.json(["v": $0]) }) {
            changes[key] = value
        }
        sentContext = next
        if !changes.isEmpty { notify("ui/notifications/host-context-changed", changes) }
    }

    // MARK: Requests

    private func request(_ id: Any, _ method: String, _ params: [String: Any]) {
        switch method {
        case "ui/initialize":
            appDisplayModes = ((params["appCapabilities"] as? [String: Any])?["availableDisplayModes"] as? [Any])?.compactMap { $0 as? String }
            let context = actions.hostContext()
            sentContext = context
            var sandbox: [String: Any] = [:]
            if let csp = reference.csp, let object = McpApp.object(McpApp.json(Self.encodable(csp))) { sandbox["csp"] = object }
            if let permissions = reference.permissions {
                sandbox["permissions"] = Dictionary(uniqueKeysWithValues: permissions.map { ($0, [String: Any]()) })
            }
            var capabilities: [String: Any] = [
                "openLinks": [String: Any](), "serverResources": [String: Any](), "logging": [String: Any](),
                "message": ["text": [String: Any]()], "updateModelContext": ["text": [String: Any](), "structuredContent": [String: Any]()],
                "downloadFile": [String: Any](), "sandbox": sandbox,
            ]
            if reference.server != nil { capabilities["serverTools"] = [String: Any]() }
            respond(id, [
                "protocolVersion": McpApp.protocolVersion,
                "hostInfo": ["name": "nook", "version": hostVersion],
                "hostCapabilities": capabilities,
                "hostContext": context,
            ])
        case "ping":
            respond(id, [String: Any]())
        case "tools/call":
            guard let name = params["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail(id, -32602, "tools/call needs a tool name and object arguments.")
            }
            let arguments = params["arguments"] ?? [String: Any]()
            guard let object = arguments as? [String: Any] else { return fail(id, -32602, "tools/call needs a tool name and object arguments.") }
            answer(id) { done in self.actions.callTool(name, object) { done($0.map { McpApp.normalizedToolResult($0) }) } }
        case "resources/read":
            guard let uri = params["uri"] as? String, !uri.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail(id, -32602, "resources/read needs a uri.")
            }
            answer(id) { done in self.actions.readResource(uri, done) }
        case "ui/open-link":
            guard let text = params["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return fail(id, -32602, "Only http(s) links can be opened.")
            }
            answer(id) { done in self.actions.openLink(url) { done($0.map { [String: Any]() }) } }
        case "ui/message":
            let blocks = (params["content"] as? [Any]) ?? [params["content"] as Any]
            let texts = blocks.map { ($0 as? [String: Any]).flatMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil } }
            guard (params["role"] as? String) == "user", !texts.isEmpty, !texts.contains(where: { $0 == nil }) else {
                return fail(id, -32602, "Only text messages from the user role are supported.")
            }
            let text = texts.compactMap { $0 }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return fail(id, -32602, "ui/message needs non-empty text.") }
            answer(id) { done in self.actions.sendMessage(text) { done($0.map { [String: Any]() }) } }
        case "ui/request-display-mode":
            let context = actions.hostContext()
            let current = (context["displayMode"] as? String) ?? "inline"
            let available = (context["availableDisplayModes"] as? [String]) ?? ["inline"]
            guard let raw = params["mode"] as? String, let mode = DisplayMode(rawValue: raw), available.contains(raw),
                  appDisplayModes.map({ $0.contains(raw) }) ?? true, raw != current else {
                return respond(id, ["mode": current])
            }
            answer(id) { done in self.actions.requestDisplayMode(mode) { done(.success(["mode": $0.rawValue])) } }
        case "ui/update-model-context":
            let content = params["content"]
            let structured = params["structuredContent"]
            guard content == nil || content is [Any], structured == nil || structured is [String: Any],
                  let text = McpApp.modelContext(content: content as? [Any], structured: structured as? [String: Any]) else {
                return fail(id, -32602, "Model context needs text content blocks or an object of structured content (at most 16 KB).")
            }
            answer(id) { done in self.actions.updateModelContext(text) { done($0.map { [String: Any]() }) } }
        case "ui/download-file":
            guard let files = Self.downloads(params["contents"]) else {
                return fail(id, -32602, "ui/download-file needs embedded resources or resource links.")
            }
            answer(id) { done in
                self.actions.downloadFiles(files) { result in
                    switch result {
                    case .success: done(.success([String: Any]()))
                    case .failure(let error as Refusal): _ = error; done(.success(["isError": true]))
                    case .failure(let error): done(.failure(error))
                    }
                }
            }
        default:
            fail(id, -32601, "Method not found: \(method)")
        }
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "ui/notifications/initialized":
            guard !initialized else { return }
            initialized = true
            sendToolCall()
            updateHostContext()
        case "ui/notifications/size-changed":
            let width = (params["width"] as? NSNumber)?.doubleValue
            let height = (params["height"] as? NSNumber)?.doubleValue
            if width != nil || height != nil { actions.onSizeChanged(width, height) }
        case "ui/notifications/request-teardown":
            actions.onRequestTeardown()
        default:
            break
        }
    }

    /// The tool's arguments and result, once, after the page says it is ready.
    private func sendToolCall() {
        guard initialized, !toolCallSent else { return }
        toolCallSent = true
        notify("ui/notifications/tool-input", ["arguments": (McpApp.object(reference.arguments) as? [String: Any]) ?? [String: Any]()])
        if let result = McpApp.object(reference.result) as? [String: Any] {
            notify("ui/notifications/tool-result", McpApp.normalizedToolResult(result))
        } else if let text = reference.result, McpApp.object(text) == nil, !text.isEmpty {
            notify("ui/notifications/tool-result", ["content": [["type": "text", "text": text]]])
        }
    }

    private func answer(_ id: Any, _ run: (@escaping (Result<[String: Any], Error>) -> Void) -> Void) {
        guard pending < McpApp.maxPendingRequests else { return fail(id, -32000, "Too many requests in flight.") }
        pending += 1
        run { [weak self] result in
            guard let self else { return }
            self.pending -= 1
            switch result {
            case .success(let value): self.respond(id, value)
            case .failure(let error):
                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                self.fail(id, -32000, message.isEmpty ? "Request failed." : message)
            }
        }
    }

    private func post(_ message: [String: Any]) { if !disposed { actions.post(message) } }
    private func notify(_ method: String, _ params: [String: Any]) { post(["jsonrpc": "2.0", "method": method, "params": params]) }
    private func respond(_ id: Any, _ result: [String: Any]) { post(["jsonrpc": "2.0", "id": id, "result": result]) }
    private func fail(_ id: Any, _ code: Int, _ message: String) {
        post(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func id(_ value: Any?) -> Any? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, number.doubleValue.isFinite { return number }
        return nil
    }

    private static func encodable(_ csp: McpApp.Csp) -> [String: Any] {
        var object: [String: Any] = [:]
        if let value = csp.connectDomains { object["connectDomains"] = value }
        if let value = csp.resourceDomains { object["resourceDomains"] = value }
        if let value = csp.frameDomains { object["frameDomains"] = value }
        if let value = csp.baseUriDomains { object["baseUriDomains"] = value }
        return object
    }

    static func downloads(_ contents: Any?) -> [Download]? {
        guard let list = contents as? [Any], !list.isEmpty else { return nil }
        var files: [Download] = []
        for entry in list {
            guard let entry = entry as? [String: Any] else { return nil }
            if (entry["type"] as? String) == "resource", let resource = entry["resource"] as? [String: Any] {
                let data: Data?
                if let text = resource["text"] as? String { data = Data(text.utf8) }
                else if let blob = resource["blob"] as? String { data = Data(base64Encoded: blob) }
                else { data = nil }
                guard let data else { return nil }
                files.append(.embedded(name: McpApp.downloadName(uri: resource["uri"] as? String, name: resource["name"] as? String),
                                       mimeType: (resource["mimeType"] as? String) ?? "application/octet-stream", data: data))
            } else if (entry["type"] as? String) == "resource_link", let uri = entry["uri"] as? String {
                files.append(.link(name: McpApp.downloadName(uri: uri, name: entry["name"] as? String), uri: uri))
            } else {
                return nil
            }
        }
        return files
    }
}
