import Foundation

// Pi (the pi.dev coding agent) in its RPC mode: `pi --mode rpc` reads commands and writes events as JSON, one per line,
// LF-delimited (a trailing CR is dropped; U+2028 and U+2029 are text, not line breaks). Nook runs one such process per
// turn, resumes the conversation from Pi's session file, and answers Pi's blocking dialogs from the extension Nook loads
// (`PiExtension`). Everything in this file depends only on Foundation so tests can use it independently.

/// What Nook writes to Pi's stdin.
enum PiRPC {
    /// The request id of the `get_state` Nook sends first, to learn the session file and the model's context window.
    static let stateRequestID = "nook-state"
    static let modelsRequestID = "nook-models"

    static func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    static func getState() -> String { line(["type": "get_state", "id": stateRequestID]) }

    static func getAvailableModels(id: String) -> String { line(["type": "get_available_models", "id": id]) }

    /// A message. While Pi works on a turn it steers that turn (`streamingBehavior`); on an idle Pi it starts one.
    static func prompt(_ message: String, steer: Bool = true) -> String {
        var object: [String: Any] = ["type": "prompt", "message": message]
        if steer { object["streamingBehavior"] = "steer" }
        return line(object)
    }

    static func abort() -> String { line(["type": "abort"]) }

    static func setModel(provider: String, modelID: String) -> String {
        line(["type": "set_model", "provider": provider, "modelId": modelID])
    }

    static func setThinkingLevel(_ level: String) -> String { line(["type": "set_thinking_level", "level": level]) }

    /// Compacts the conversation; a non-empty `instructions` says what the summary should keep.
    static func compact(_ instructions: String = "") -> String {
        let clean = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return line(clean.isEmpty ? ["type": "compact"] : ["type": "compact", "customInstructions": clean])
    }

    /// The answer to a `confirm` dialog.
    static func confirmResponse(requestID: String, confirmed: Bool) -> String {
        line(["type": "extension_ui_response", "id": requestID, "confirmed": confirmed])
    }

    /// The commands a turn starts with: Nook's "/compact" is Pi's `compact` command (a prompt of "/compact" would only
    /// reach the model), every other message a prompt. `get_state` goes first so the session is known before the turn ends.
    static func turnInput(for message: String) -> [String] {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/compact" { return [getState(), compact()] }
        if trimmed.hasPrefix("/compact ") { return [getState(), compact(String(trimmed.dropFirst(9)))] }
        return [getState(), prompt(message, steer: false)]
    }

    /// Pi names a model "provider/model" (the provider may itself contain no slash; the model id may).
    static func splitModel(_ slug: String) -> (provider: String, modelID: String)? {
        guard let slash = slug.firstIndex(of: "/"), slash != slug.startIndex, slug.index(after: slash) != slug.endIndex else { return nil }
        return (String(slug[..<slash]), String(slug[slug.index(after: slash)...]))
    }

    /// Pi's thinking levels, lowest first (`set_thinking_level`).
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh"]
}

/// One model Pi can use (`get_available_models`).
struct PiModel: Equatable, Sendable {
    var provider: String
    var id: String
    var name: String
    var contextWindow: Int?
    var supportsThinking: Bool

    /// What Nook shows and sends as the model: "provider/id".
    var slug: String { provider + "/" + id }

    /// The models when `line` is Pi's answer to Nook's `get_available_models`; nil for any other line.
    static func reply(in line: String) -> [PiModel]? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              (object["type"] as? String) == "response", (object["id"] as? String) == PiRPC.modelsRequestID else { return nil }
        return (object["success"] as? Bool) == true ? parse(object["data"]) : []
    }

    /// The models in a `get_available_models` response (`data`), without duplicates and without entries lacking a provider or id.
    static func parse(_ data: Any?) -> [PiModel] {
        guard let models = (data as? [String: Any])?["models"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var result: [PiModel] = []
        for model in models {
            guard let provider = (model["provider"] as? String)?.trimmingCharacters(in: .whitespaces), !provider.isEmpty,
                  let id = (model["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { continue }
            guard seen.insert(provider + "/" + id).inserted else { continue }
            result.append(PiModel(provider: provider, id: id, name: (model["name"] as? String) ?? id,
                                  contextWindow: (model["contextWindow"] as? NSNumber)?.intValue,
                                  supportsThinking: (model["reasoning"] as? Bool) ?? false))
        }
        return result
    }
}

/// What Nook extracts from one line of Pi's RPC output.
enum PiStreamEvent: Equatable, Sendable {
    /// `get_state`: the session file (what `--session` resumes), the model and its context window.
    case session(file: String?, model: String?, contextWindow: Int?)
    case started
    case textDelta(String)
    case thinkingDelta(String)
    /// A whole answer or thought block, which replaces what streamed for it.
    case text(String)
    case thinking(String)
    case toolStarted(id: String, name: String, input: JSONBox)
    case toolUpdated(id: String, output: String)
    case toolFinished(id: String, name: String, output: String, isError: Bool)
    /// A model call finished: its tokens, and the cost Pi reports.
    case usage(PiUsage)
    /// A blocking `confirm` dialog of an extension: Nook's approval extension asks before a tool runs.
    case confirm(requestID: String, title: String, message: String)
    /// A dialog Nook does not draw (select, input, editor): answered as cancelled so the extension goes on.
    case unsupportedDialog(requestID: String)
    /// Something Pi or an extension wants you to know.
    case notice(String)
    case compactionStarted
    case compactionEnded(failed: String?)
    /// Pi retries a failed model call.
    case retrying(String)
    case failed(String)
    /// The agent finished its turn (nothing left to run, no retry, no queued message).
    case settled(aborted: Bool)
    /// The older end-of-run event; a newer Pi follows it with `settled`.
    case ended
    /// A command Pi answered (`compact` reports its end through this when it started no run).
    case commandDone(command: String, error: String?)
}

struct PiUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var total = 0
    var costUSD: Double?
}

extension TurnUsage {
    /// Adds one model call of a Pi turn: its tokens and cost count up, the context is that of the latest call.
    mutating func add(_ call: PiUsage, contextWindow window: Int?) {
        inputTokens = (inputTokens ?? 0) + call.input
        outputTokens = (outputTokens ?? 0) + call.output
        cacheReadTokens = (cacheReadTokens ?? 0) + call.cacheRead
        cacheWriteTokens = (cacheWriteTokens ?? 0) + call.cacheWrite
        if let cost = call.costUSD { reportedCostUSD = (reportedCostUSD ?? 0) + cost }
        contextTokens = call.total
        contextWindow = window
    }
}

enum PiStreamParser {
    static func parse(_ line: String) -> [PiStreamEvent] {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "response":
            return response(object)
        case "agent_start":
            return [.started]
        case "message_update":
            return messageUpdate(object)
        case "message_end":
            guard let message = object["message"] as? [String: Any], (message["role"] as? String) == "assistant" else { return [] }
            var events: [PiStreamEvent] = []
            if let usage = usage(message["usage"]) { events.append(.usage(usage)) }
            if (message["stopReason"] as? String) == "error" {
                events.append(.failed((message["errorMessage"] as? String) ?? "Pi reported a model error."))
            }
            return events
        case "tool_execution_start":
            guard let id = object["toolCallId"] as? String else { return [] }
            return [.toolStarted(id: id, name: (object["toolName"] as? String) ?? "tool",
                                 input: JSONBox((object["args"] as? [String: Any]) ?? [:]))]
        case "tool_execution_update":
            guard let id = object["toolCallId"] as? String else { return [] }
            let text = contentText((object["partialResult"] as? [String: Any])?["content"])
            return text.isEmpty ? [] : [.toolUpdated(id: id, output: text)]
        case "tool_execution_end":
            guard let id = object["toolCallId"] as? String else { return [] }
            let text = contentText((object["result"] as? [String: Any])?["content"])
            return [.toolFinished(id: id, name: (object["toolName"] as? String) ?? "tool", output: text,
                                  isError: (object["isError"] as? Bool) ?? false)]
        case "compaction_start":
            return [.compactionStarted]
        case "compaction_end":
            if (object["aborted"] as? Bool) == true { return [.compactionEnded(failed: "")] }
            let failure = object["errorMessage"] as? String
            return [.compactionEnded(failed: failure.flatMap { $0.isEmpty ? nil : $0 })]
        case "auto_retry_start":
            return [.retrying((object["errorMessage"] as? String) ?? "")]
        case "extension_ui_request":
            return dialog(object)
        case "extension_error":
            let message = (object["error"] as? String) ?? "An extension failed."
            return [.notice(message)]
        case "agent_settled":
            return [.settled(aborted: (object["aborted"] as? Bool) ?? false)]
        case "agent_end":
            return [.ended]
        default:
            return []
        }
    }

    private static func response(_ object: [String: Any]) -> [PiStreamEvent] {
        let command = (object["command"] as? String) ?? ""
        let success = (object["success"] as? Bool) ?? false
        let error = success ? nil : (object["error"] as? String) ?? "Pi rejected the \(command) command."
        if command == "get_state", success, (object["id"] as? String) == PiRPC.stateRequestID {
            let state = object["data"] as? [String: Any] ?? [:]
            let model = state["model"] as? [String: Any]
            let slug = (model?["provider"] as? String).flatMap { provider in (model?["id"] as? String).map { provider + "/" + $0 } }
            return [.session(file: state["sessionFile"] as? String, model: slug, contextWindow: (model?["contextWindow"] as? NSNumber)?.intValue)]
        }
        // A prompt that failed to start ends the turn; a compact that started no run reports its end here.
        if command == "prompt", let error { return [.failed(error), .settled(aborted: false)] }
        if command == "compact" { return [.commandDone(command: command, error: error)] }
        if let error, command != "get_state" { return [.notice(error)] }
        return []
    }

    private static func messageUpdate(_ object: [String: Any]) -> [PiStreamEvent] {
        guard let delta = object["assistantMessageEvent"] as? [String: Any], let kind = delta["type"] as? String else { return [] }
        switch kind {
        case "text_delta": return (delta["delta"] as? String).map { [.textDelta($0)] } ?? []
        case "thinking_delta": return (delta["delta"] as? String).map { [.thinkingDelta($0)] } ?? []
        case "text_end": return (delta["content"] as? String).map { [.text($0)] } ?? []
        case "thinking_end": return (delta["content"] as? String ?? delta["thinking"] as? String).map { [.thinking($0)] } ?? []
        default: return []
        }
    }

    private static func dialog(_ object: [String: Any]) -> [PiStreamEvent] {
        guard let method = object["method"] as? String else { return [] }
        switch method {
        case "confirm":
            guard let id = object["id"] as? String else { return [] }
            return [.confirm(requestID: id, title: (object["title"] as? String) ?? "", message: (object["message"] as? String) ?? "")]
        case "select", "input", "editor":
            guard let id = object["id"] as? String else { return [] }
            return [.unsupportedDialog(requestID: id)]
        case "notify":
            let message = (object["message"] as? String) ?? ""
            return message.isEmpty ? [] : [.notice(message)]
        default:
            return []
        }
    }

    private static func usage(_ value: Any?) -> PiUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        var result = PiUsage(input: int("input"), output: int("output"), cacheRead: int("cacheRead"), cacheWrite: int("cacheWrite"),
                             total: int("totalTokens"))
        if result.total == 0 { result.total = result.input + result.output + result.cacheRead + result.cacheWrite }
        result.costUSD = ((usage["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue
        return result
    }

    /// The text blocks of a tool result's `content`.
    private static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }
}
