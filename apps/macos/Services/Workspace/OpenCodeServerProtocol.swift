import Foundation

// OpenCode 2's own server (`opencode serve`): the HTTP API and event stream its TUI uses. Nook starts one per account on
// 127.0.0.1 with a port the system picks and a password of its own (`OpenCodeServerHost`), and drives every OpenCode
// session of that account through it (`WorkspaceManager+OpenCodeServer`). It says more than OpenCode's ACP server:
// questions as forms, a reason with a denial, the model's variants (Nook's effort), per-step tokens and cost, and an
// interrupt that answers whether anything was running. This file only builds requests and reads events, so the tests
// run it against recorded streams without OpenCode installed.
//
// Learned from OpenCode 2.2.7's `/openapi.json` and its stream, and from OpenCode 2 adapter: the event stream is
// volatile (subscribe before the first prompt), heartbeats come every 10-15 s, a rejection without a message cancels
// the whole execution, and the last matching permission rule wins.

enum OpenCodeServe {
    /// The first OpenCode 2 whose server API Nook speaks (floor too). OpenCode 1.x also has `serve`, with an
    /// older API: those run over ACP.
    static let minimumVersion = CLIVersion("2.0.18")!

    static func supports(version: String?) -> Bool {
        guard let version, let parsed = CLIVersion(version) else { return false }
        return parsed >= minimumVersion
    }

    /// Loopback only, and a port the system picks; the URL is read from what the server prints.
    static let arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
    /// OpenCode 2 requires a password and prints a generated one otherwise: Nook gives its own through the environment
    /// (never on the command line). `OPENCODE_SERVER_PASSWORD` is 1.x's name for it and is dropped.
    static let passwordVariable = "OPENCODE_PASSWORD"
    static let removedEnvironment = ["OPENCODE_SERVER_PASSWORD"]
    /// HTTP Basic, always with this user name.
    static let user = "opencode"

    /// A fresh random password: 32 bytes from the system's secure generator, base64url.
    static func makePassword() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The `Authorization` header (UTF-8 credentials).
    static func authorization(password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// The server's address from its first line: "Server listening on http://127.0.0.1:60163". Only a loopback address
    /// counts.
    static func listeningURL(inLine line: String) -> URL? {
        guard let range = line.range(of: "http://127.0.0.1:") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        guard let port = Int(digits), (1...65_535).contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// `location[directory]=…`: which folder (OpenCode's "location") a request is about.
    static func locationQuery(_ directory: String) -> [URLQueryItem] {
        [URLQueryItem(name: "location[directory]", value: directory)]
    }

    // MARK: Requests

    /// A model as OpenCode names it, from Nook's "provider/model" (the id its ACP server uses too), with the session's
    /// effort as the model's variant. Nil for the agent's default.
    static func modelRef(_ model: String, effort: String?) -> [String: Any]? {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/"), slash != trimmed.startIndex else { return nil }
        let provider = String(trimmed[..<slash])
        let id = String(trimmed[trimmed.index(after: slash)...])
        guard !id.isEmpty else { return nil }
        var ref: [String: Any] = ["providerID": provider, "id": id]
        if let effort, !effort.isEmpty { ref["variant"] = effort }
        return ref
    }

    /// "provider/model" of a model reference, and its variant ("default" means none).
    static func model(_ ref: Any?) -> (id: String, variant: String?)? {
        guard let ref = ref as? [String: Any], let provider = ref["providerID"] as? String, let id = ref["id"] as? String,
              !provider.isEmpty, !id.isEmpty else { return nil }
        let variant = (ref["variant"] as? String).flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        return (provider + "/" + id, variant)
    }

    /// The agent for the session's mode: OpenCode's own `plan` agent reads and plans, `build` works.
    static func agent(for mode: ExecutionMode) -> String {
        switch mode {
        case .agent: return "build"
        case .plan: return "plan"
        }
    }

    /// The name of Nook's bridge in OpenCode for one session: OpenCode hides tools of names over 64 characters.
    static func bridgeServer(runID: UUID) -> String {
        "nook-" + runID.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
    }

    /// A permission rule (`Permission.Rule`).
    struct Rule: Equatable, Sendable {
        var action: String
        var resource: String
        var effect: String

        var json: [String: String] { ["action": action, "resource": resource, "effect": effect] }
    }

    /// The session's rules for what it may do without asking. The last rule that matches wins, so the session's rights
    /// come first, then what you allowed "for this session", then Plan mode's ban on edits, and last Nook's bridge: only
    /// this session's own (one server serves every session of the folder).
    static func rules(permission: PermissionPolicy, mode: ExecutionMode, grants: [Rule], bridgeServer: String?) -> [Rule] {
        var rules: [Rule]
        switch permission {
        case .bypass:
            rules = [Rule(action: "*", resource: "*", effect: "allow")]
        case .acceptEdits, .auto:
            // OpenCode has no reviewer of its own: "auto" is not offered, an old setting edits only.
            rules = [Rule(action: "shell", resource: "*", effect: "ask"), Rule(action: "edit", resource: "*", effect: "allow"),
                     Rule(action: "external_directory", resource: "*", effect: "ask")]
        case .ask:
            rules = [Rule(action: "shell", resource: "*", effect: "ask"), Rule(action: "edit", resource: "*", effect: "ask"),
                     Rule(action: "external_directory", resource: "*", effect: "ask")]
        }
        rules += grants
        if mode == .plan { rules.append(Rule(action: "edit", resource: "*", effect: "deny")) }
        if let bridgeServer {
            rules.append(Rule(action: "nook-*", resource: "*", effect: "deny"))
            rules.append(Rule(action: bridgeServer + "_*", resource: "*", effect: "allow"))
        }
        return rules
    }

    /// What "Always" allows for the rest of the session: the patterns OpenCode offers to save ("ls *"). Kept in the
    /// session's rules rather than OpenCode's "always", which it saves for the whole project.
    static func grants(action: String, save: [String]) -> [Rule] {
        (save.isEmpty ? ["*"] : save).map { Rule(action: action, resource: $0, effect: "allow") }
    }

    /// Words OpenCode tells the model with a denial that has no reason of its own: a rejection without a message ends
    /// the whole execution, as Stop would.
    static let declined = "The user declined this request."

    /// The answer to a permission request. A denial always carries a message, so the turn goes on without the action.
    static func permissionReply(allow: Bool, reason: String) -> [String: Any] {
        guard !allow else { return ["decision": "once"] }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["decision": "reject", "message": text.isEmpty ? declined : text]
    }

    /// A prompt: your words and the files that go with them (pictures as `file:` links OpenCode reads itself).
    static func promptBody(text: String, files: [String]) -> [String: Any] {
        var body: [String: Any] = ["text": text]
        let attachments = files.map { path -> [String: Any] in
            ["uri": URL(fileURLWithPath: path).absoluteString, "name": (path as NSString).lastPathComponent]
        }
        if !attachments.isEmpty { body["files"] = attachments }
        return body
    }

    /// A new session in `directory`.
    static func newSessionBody(directory: String, model: [String: Any]?, agent: String, rules: [Rule]) -> [String: Any] {
        var body: [String: Any] = ["location": ["directory": directory], "agent": agent, "permissions": rules.map(\.json)]
        if let model { body["model"] = model }
        return body
    }

    /// Nook's bridge as a local MCP server of OpenCode's.
    static func bridgeConfig(command: String, arguments: [String], environment: [String: String]) -> [String: Any] {
        ["config": ["type": "local", "command": [command] + arguments, "environment": environment]]
    }

    /// The answer to a form: per field the chosen labels, one text for a single choice.
    static func formAnswer(_ form: OpenCodeForm, answers: [String: [String]]) -> [String: Any] {
        var answer: [String: Any] = [:]
        for field in form.fields {
            let values = (answers[field.key] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !values.isEmpty else { continue }
            // A label shown for an option goes back as that option's value.
            let mapped = values.map { value in field.options.first { $0.label == value }?.value ?? value }
            answer[field.key] = field.multiSelect ? mapped : mapped.joined(separator: ", ")
        }
        return ["answer": answer]
    }

    /// A `/` command of OpenCode's in a prompt: `/compact` alone, or a command it listed with what follows it.
    static func command(in prompt: String, known: [AgentSlashCommand]) -> (name: String, text: String)? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard !name.isEmpty else { return nil }
        let rest = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "compact" { return (name, rest) }
        guard known.contains(where: { $0.name == name }) else { return nil }
        return (name, rest)
    }

    // MARK: Responses

    /// A model OpenCode offers: Nook's id for it, its name, its variants (the effort levels) and context window.
    struct Model: Equatable, Sendable {
        var id: String
        var name: String
        var variants: [String]
        var contextWindow: Int?
    }

    /// `GET /api/model` (and `/api/model/default`'s `data`): the enabled chat models.
    static func models(_ response: Any?) -> [Model] {
        let data = (response as? [String: Any])?["data"]
        let list = (data as? [[String: Any]]) ?? (data as? [String: Any]).map { [$0] } ?? []
        return list.compactMap { item in
            guard (item["enabled"] as? Bool) != false, (item["type"] as? String ?? "chat") == "chat",
                  (item["status"] as? String ?? "active") != "deprecated",
                  let provider = item["providerID"] as? String, let id = item["id"] as? String else { return nil }
            let full = provider + "/" + id
            let name = (item["name"] as? String).map { provider + "/" + $0 } ?? full
            let variants = ((item["variants"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
            let window = ((item["limit"] as? [String: Any])?["context"] as? NSNumber)?.intValue
            return Model(id: full, name: name, variants: variants, contextWindow: window)
        }
    }

    /// `GET /api/command`: the commands to offer after `/`.
    static func commands(_ response: Any?) -> [AgentSlashCommand] {
        let list = ((response as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        return list.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty, !name.contains(where: \.isWhitespace),
                  seen.insert(name).inserted else { return nil }
            return AgentSlashCommand(name: name, detail: item["description"] as? String, takesInput: true)
        }
    }

    /// `GET /api/session/{id}`: the session, nil when the answer has none.
    static func session(_ response: Any?) -> OpenCodeSessionInfo? {
        guard let data = (response as? [String: Any])?["data"] as? [String: Any], let id = data["id"] as? String else { return nil }
        let time = (data["time"] as? [String: Any]) ?? [:]
        let busy = (time["busy"] as? NSNumber)?.doubleValue
        let idle = (time["idle"] as? NSNumber)?.doubleValue
        return OpenCodeSessionInfo(id: id, parentID: data["parentID"] as? String,
                                   directory: (data["location"] as? [String: Any])?["directory"] as? String,
                                   model: model(data["model"])?.id, variant: model(data["model"])?.variant,
                                   busy: busy.map { started in idle.map { started > $0 } ?? true } ?? false,
                                   outcome: data["outcome"] as? String)
    }

    /// The answer to `POST …/interrupt`: whether something was running and is stopped now.
    static func interrupted(_ response: Any?) -> Bool? {
        (response as? [String: Any])?["interrupted"] as? Bool
    }

    /// The text of an error answer (`{"_tag":…,"message":…}`).
    static func errorMessage(_ response: Any?) -> String? {
        guard let object = response as? [String: Any] else { return nil }
        return (object["message"] as? String) ?? (object["_tag"] as? String)
    }
}

/// What Nook reads of a session.
struct OpenCodeSessionInfo: Equatable, Sendable {
    var id: String
    /// The session that started this one (a subagent's).
    var parentID: String?
    var directory: String?
    var model: String?
    var variant: String?
    /// Working right now (busy since it was last idle).
    var busy: Bool
    /// How its last execution ended: succeeded, failed, interrupted.
    var outcome: String?
}

// MARK: - Events

/// Tokens of one model call (a "step").
struct OpenCodeTokens: Equatable, Sendable {
    var input = 0
    var output = 0
    var reasoning = 0
    var cacheRead = 0
    var cacheWrite = 0

    init(input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any] else { return nil }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let cache = (raw["cache"] as? [String: Any]) ?? [:]
        self.init(input: int(raw["input"]), output: int(raw["output"]), reasoning: int(raw["reasoning"]),
                  cacheRead: int(cache["read"]), cacheWrite: int(cache["write"]))
    }

    /// What was in the context for this call.
    var context: Int { input + cacheRead + cacheWrite }
}

/// A permission request (`permission.asked`): an action ("shell", "edit", "external_directory", an MCP tool), what it
/// is about ("ls", a path), and what "always" would save ("ls *").
struct OpenCodePermission: Equatable, Sendable {
    var id: String
    var sessionID: String
    var action: String
    var resources: [String]
    var save: [String]
    /// The tool call that asks, when a tool asks.
    var callID: String?
    var message: String?

    init(id: String, sessionID: String, action: String, resources: [String], save: [String], callID: String? = nil,
         message: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.action = action
        self.resources = resources
        self.save = save
        self.callID = callID
        self.message = message
    }

    /// A request as `permission.asked` carries it, and as `GET …/permission` lists it.
    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let id = raw["id"] as? String, let session = raw["sessionID"] as? String,
              let action = raw["action"] as? String else { return nil }
        self.init(id: id, sessionID: session, action: action, resources: raw["resources"] as? [String] ?? [],
                  save: raw["save"] as? [String] ?? [], callID: (raw["source"] as? [String: Any])?["id"] as? String,
                  message: raw["message"] as? String)
    }
}

/// A form (`form.created`): the questions the agent asks (its `question` tool), or what a plugin asks.
struct OpenCodeForm: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        var value: String
        var label: String
        var description: String
    }

    struct Field: Equatable, Sendable {
        var key: String
        var title: String
        var description: String
        var options: [Option]
        var multiSelect: Bool
        var custom: Bool
    }

    var id: String
    var sessionID: String
    var title: String
    var fields: [Field]
    /// The tool call that asks.
    var callID: String?
    /// Something Nook cannot show as a question (a link to open, a number, a field that depends on another): such a form
    /// is cancelled with a note.
    var unsupported: String?

    /// The questions in Nook's question panel.
    var questions: [RunQuestion] {
        fields.map { field in
            RunQuestion(id: field.key, header: field.title, question: field.description.isEmpty ? field.title : field.description,
                        options: field.options.map { RunQuestionOption(label: $0.label, description: $0.description) },
                        multiSelect: field.multiSelect, allowsOther: field.custom || field.options.isEmpty)
        }
    }

    init(id: String, sessionID: String, title: String, fields: [Field], callID: String? = nil, unsupported: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.fields = fields
        self.callID = callID
        self.unsupported = unsupported
    }

    init?(_ raw: Any?) {
        guard let raw = raw as? [String: Any], let id = raw["id"] as? String, let session = raw["sessionID"] as? String else { return nil }
        var fields: [Field] = []
        var unsupported: String?
        for (index, item) in ((raw["fields"] as? [[String: Any]]) ?? []).enumerated() {
            let type = item["type"] as? String ?? ""
            if (item["hidden"] as? Bool) == true { unsupported = unsupported ?? "a hidden field" }
            if let when = item["when"] as? [Any], !when.isEmpty { unsupported = unsupported ?? "a field that depends on another" }
            guard type == "string" || type == "multiselect" else {
                unsupported = unsupported ?? (type == "external" ? "a link to open" : "a \(type) value")
                continue
            }
            let options = ((item["options"] as? [[String: Any]]) ?? []).compactMap { option -> Option? in
                let value = option["value"] as? String ?? ""
                let label = (option["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value
                guard !label.isEmpty else { return nil }
                return Option(value: value.isEmpty ? label : value, label: label,
                              description: (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label)
            }
            fields.append(Field(key: item["key"] as? String ?? "q\(index)", title: (item["title"] as? String) ?? "",
                                description: (item["description"] as? String) ?? "", options: options,
                                multiSelect: type == "multiselect", custom: (item["custom"] as? Bool) == true))
        }
        let tool = ((raw["metadata"] as? [String: Any])?["tool"] as? [String: Any])?["id"] as? String
        self.init(id: id, sessionID: session, title: raw["title"] as? String ?? "", fields: fields, callID: tool,
                  unsupported: fields.isEmpty ? (unsupported ?? "an empty form") : unsupported)
    }
}

/// One event of the server's stream (`GET /api/event`), as far as Nook uses it. Events of a session carry its id.
enum OpenCodeEvent: Equatable, Sendable {
    /// How an execution (the work one prompt, or a steer, set off) ended.
    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed(kind: String, message: String)
        case interrupted(reason: String)
    }

    /// The stream is open: from now on nothing is missed.
    case connected
    case executionStarted(session: String)
    case executionEnded(session: String, Outcome)
    /// More of an answer (`thinking` false) or a thought, by the message and the part's place in it.
    case textDelta(session: String, item: String, thinking: Bool, text: String)
    /// The whole part: replaces what streamed.
    case textDone(session: String, item: String, thinking: Bool, text: String)
    /// The model starts writing a tool call.
    case toolStarted(session: String, call: String, name: String)
    /// The call is complete and runs (or waits for permission).
    case toolCalled(session: String, call: String, input: JSONBox)
    case toolSucceeded(session: String, call: String, output: String, metadata: JSONBox)
    /// `kind` "aborted" for a call Stop ended, "permission.rejected" for one you denied.
    case toolFailed(session: String, call: String, kind: String, message: String)
    /// A model call ended: its tokens and cost.
    case stepEnded(session: String, tokens: OpenCodeTokens?, cost: Double?)
    case permission(OpenCodePermission)
    /// Answered (by Nook, or by another client of the same server).
    case permissionSettled(session: String, request: String)
    case form(OpenCodeForm)
    case formSettled(session: String, form: String)
    case retrying(session: String, message: String)
    case compactionStarted(session: String)
    case compactionEnded(session: String, failed: String?)
    /// The session runs another model now (`session.model.selected`): "provider/model".
    case modelSelected(session: String, model: String, variant: String?)
    /// Anything else, kept only for its type and session.
    case other(type: String, session: String?)

    var sessionID: String? {
        switch self {
        case .connected: return nil
        case .executionStarted(let session), .executionEnded(let session, _), .textDelta(let session, _, _, _),
             .textDone(let session, _, _, _), .toolStarted(let session, _, _), .toolCalled(let session, _, _),
             .toolSucceeded(let session, _, _, _), .toolFailed(let session, _, _, _), .stepEnded(let session, _, _),
             .permissionSettled(let session, _), .formSettled(let session, _), .retrying(let session, _),
             .compactionStarted(let session), .compactionEnded(let session, _), .modelSelected(let session, _, _):
            return session
        case .permission(let request): return request.sessionID
        case .form(let form): return form.sessionID
        case .other(_, let session): return session
        }
    }

    /// One frame's `data`. Nil for what is not an event (a broken frame); an event of a type Nook does not read is
    /// `.other`, so a newer server's events never break the stream.
    static func decode(_ data: String) -> OpenCodeEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let body = (object["data"] as? [String: Any]) ?? [:]
        let session = body["sessionID"] as? String
        func string(_ key: String) -> String { body[key] as? String ?? "" }
        func item() -> String { string("assistantMessageID") + ":" + ((body["ordinal"] as? NSNumber)?.stringValue ?? "0") }
        guard let session else {
            switch type {
            case "server.connected": return .connected
            case "form.created":
                return OpenCodeForm(body["form"]).map(OpenCodeEvent.form) ?? .other(type: type, session: nil)
            default: return .other(type: type, session: nil)
            }
        }
        switch type {
        case "session.execution.started": return .executionStarted(session: session)
        case "session.execution.succeeded": return .executionEnded(session: session, .succeeded)
        case "session.execution.interrupted": return .executionEnded(session: session, .interrupted(reason: string("reason")))
        case "session.execution.failed":
            let error = (body["error"] as? [String: Any]) ?? [:]
            return .executionEnded(session: session, .failed(kind: error["type"] as? String ?? "", message: Self.message(of: error)))
        case "session.text.delta", "session.reasoning.delta":
            return .textDelta(session: session, item: item(), thinking: type.hasPrefix("session.reasoning"), text: string("delta"))
        case "session.text.ended", "session.reasoning.ended":
            return .textDone(session: session, item: item(), thinking: type.hasPrefix("session.reasoning"), text: string("text"))
        case "session.tool.input.started":
            return .toolStarted(session: session, call: string("id"), name: string("name"))
        case "session.tool.called":
            return .toolCalled(session: session, call: string("id"), input: JSONBox(body["input"] as? [String: Any] ?? [:]))
        case "session.tool.success":
            return .toolSucceeded(session: session, call: string("id"), output: Self.text(body["content"]),
                                  metadata: JSONBox(body["metadata"] as? [String: Any] ?? [:]))
        case "session.tool.failed":
            let error = (body["error"] as? [String: Any]) ?? [:]
            return .toolFailed(session: session, call: string("id"), kind: error["type"] as? String ?? "", message: Self.message(of: error))
        case "session.step.ended", "session.step.failed":
            return .stepEnded(session: session, tokens: OpenCodeTokens(body["tokens"]), cost: (body["cost"] as? NSNumber)?.doubleValue)
        case "permission.asked":
            return OpenCodePermission(body).map(OpenCodeEvent.permission) ?? .other(type: type, session: session)
        case "permission.replied": return .permissionSettled(session: session, request: string("requestID"))
        case "form.replied", "form.cancelled": return .formSettled(session: session, form: string("id"))
        case "session.retry.scheduled":
            return .retrying(session: session, message: Self.message(of: (body["error"] as? [String: Any]) ?? [:]))
        case "session.compaction.started": return .compactionStarted(session: session)
        case "session.compaction.ended": return .compactionEnded(session: session, failed: nil)
        case "session.compaction.failed":
            return .compactionEnded(session: session, failed: Self.message(of: (body["error"] as? [String: Any]) ?? [:]))
        case "session.model.selected":
            guard let model = OpenCodeServe.model(body["model"]) else { return .other(type: type, session: session) }
            return .modelSelected(session: session, model: model.id, variant: model.variant)
        default: return .other(type: type, session: session)
        }
    }

    private static func message(of error: [String: Any]) -> String {
        (error["message"] as? String) ?? (error["type"] as? String) ?? ""
    }

    /// The text parts of a tool's content.
    private static func text(_ content: Any?) -> String {
        ((content as? [[String: Any]]) ?? []).compactMap { part in
            (part["type"] as? String) == "text" ? part["text"] as? String : nil
        }.joined(separator: "\n")
    }
}

/// A tool call as OpenCode names it, in the shape Nook's timeline reads (Claude Code's keys: `file_path`, `old_string`):
/// edits count as file changes and open their file, as for every other agent.
enum OpenCodeTools {
    static func input(tool: String, _ input: [String: Any], directory: String) -> [String: Any] {
        var mapped = input
        if let path = input["path"] as? String, !path.isEmpty {
            mapped["file_path"] = absolute(path, in: directory)
        }
        switch tool {
        case "edit":
            if let old = input["oldString"] { mapped["old_string"] = old }
            if let new = input["newString"] { mapped["new_string"] = new }
        default:
            break
        }
        return mapped
    }

    /// Nook's tool name for the row: OpenCode's own, with its writes and edits under the names the timeline knows.
    static func name(_ tool: String) -> String {
        switch tool {
        case "edit": return "Edit"
        case "write": return "Write"
        default: return tool
        }
    }

    /// Files a successful call changed: the edited and written paths, and what its metadata lists.
    static func changedPaths(tool: String, input: [String: Any], metadata: [String: Any], directory: String) -> [String] {
        var paths: [String] = []
        if tool == "edit" || tool == "write", let path = input["path"] as? String, !path.isEmpty { paths.append(absolute(path, in: directory)) }
        for file in (metadata["files"] as? [[String: Any]]) ?? [] {
            if let path = file["file"] as? String, !path.isEmpty {
                let full = absolute(path, in: directory)
                if !paths.contains(full) { paths.append(full) }
            }
        }
        return paths
    }

    static func absolute(_ path: String, in directory: String) -> String {
        path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
    }
}
