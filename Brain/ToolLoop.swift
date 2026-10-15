import Foundation

/// An action the brain proposes. Nothing runs until the user approves it.
struct PlannedAction: Identifiable {
    let id = UUID()
    let tool: String
    /// Can still change: the user may edit a proposal before executing it.
    var input: [String: Any]
}

struct BrainPlan {
    var text: String
    var actions: [PlannedAction]
}

/// A single previous turn in the conversation, so follow-up questions ("what about next week?", "make it shorter") are understood.
struct ChatTurn {
    let fromUser: Bool
    let text: String
}

/// A tool as the loop sees it: what the model may call, and how to run it.
struct LoopTool {
    enum Kind { case read, action }

    let name: String
    let description: String
    let schema: [String: Any]
    let kind: Kind
    let run: ([String: Any]) async throws -> String
}

/// One tool call requested by a model.
struct ToolCallRequest {
    var id: String
    var name: String
    var input: [String: Any]
}

/// What a model returned in one round.
struct ModelTurn {
    var text: String
    var calls: [ToolCallRequest]
    /// The provider says it is done (no further round needed even if text contains JSON).
    var finished = false
}

/// One provider's conversation (Anthropic, OpenAI-compatible, Ollama, Claude Code…): it keeps its own message format.
/// The loop asks it for a round, hands back tool results, and repeats.
@MainActor
protocol ModelConversation: AnyObject {
    /// Runs one round with these tools available. `onText` receives the visible text so far.
    func next(tools: [LoopTool], onText: ((String) -> Void)?) async throws -> ModelTurn
    /// Adds the results of the calls of the last round (same order), before the next round.
    func addResults(_ results: [(call: ToolCallRequest, output: String, isError: Bool)])
    /// Asks the model to finish with a plain answer, without further tools.
    func addInstruction(_ text: String)
}

/// The one place where tool calls of any model are handled. Every runtime (cloud, local server, Claude Code, MLX)
/// goes through this, so they all behave the same:
/// - read tools run right away, their output is wrapped as untrusted data;
/// - action tools are never run here: they become proposals, after their input is checked;
/// - a call with invalid input gets one chance to be repaired, with the exact problem;
/// - unknown tools get the list of valid names back;
/// - identical read calls are answered from the first result;
/// - limits on rounds and calls stop a model that keeps calling tools.
@MainActor
final class ToolRunner {
    struct Limits {
        var rounds = 6
        var calls = 12
        /// How many times a model may retry an action whose input was invalid.
        var repairs = 2
    }

    /// Checks an action's input; returns problems in plain language (empty = fine).
    typealias Validator = (_ tool: String, _ input: [String: Any], _ schema: [String: Any]) -> [String]
    /// Cleans an action's input before it is proposed (trims, coerces types, drops unknown fields).
    typealias Normalizer = (_ input: [String: Any], _ schema: [String: Any]) -> [String: Any]

    private(set) var tools: [LoopTool]
    let limits: Limits
    private let validate: Validator
    private let normalize: Normalizer
    /// Lets the set of tools grow while the loop runs (a tool that unlocks a source's tools).
    var onToolsChanged: (([LoopTool]) -> Void)?

    private(set) var actions: [PlannedAction] = []
    private(set) var callCount = 0
    private var repairsUsed = 0
    private var cache: [String: String] = [:]
    /// Names of tools that were called, in order (for tests and diagnostics).
    private(set) var trace: [String] = []

    init(tools: [LoopTool], limits: Limits = Limits(), validate: @escaping Validator = { _, _, _ in [] },
         normalize: @escaping Normalizer = { input, _ in input }) {
        self.tools = tools
        self.limits = limits
        self.validate = validate
        self.normalize = normalize
    }

    func replaceTools(_ tools: [LoopTool]) {
        self.tools = tools
    }

    static let proposed = "Proposed to the user. It will only be executed after their confirmation."
    static let enough = "Enough information has been collected. Answer now without calling further tools."

    /// Handles one call and returns what the model should see. `isError` marks failures for providers that support it.
    func handle(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        callCount += 1
        trace.append(name)
        if callCount > limits.calls { return (Self.enough, false) }
        guard let tool = tools.first(where: { $0.name == name }) else {
            let names = tools.map(\.name).sorted().joined(separator: ", ")
            return ("Unknown tool \"\(name)\". Available tools: \(names.isEmpty ? "none" : names).", true)
        }
        switch tool.kind {
        case .read:
            let key = Self.cacheKey(name, input)
            if let cached = cache[key] { return (cached, false) }
            do {
                let output = UntrustedText.wrap(try await tool.run(input))
                cache[key] = output
                return (output, false)
            } catch {
                return ("Error: \(error.localizedDescription)", true)
            }
        case .action:
            let clean = normalize(input, tool.schema)
            let problems = validate(name, clean, tool.schema)
            if !problems.isEmpty, repairsUsed < limits.repairs {
                repairsUsed += 1
                return ("Not proposed: " + problems.joined(separator: "; ") + ". Fix these fields and call \(name) again.", true)
            }
            // Out of repair attempts: propose anyway; the review screen shows the problems and blocks running it.
            if actions.contains(where: { $0.tool == name && Self.cacheKey($0.tool, $0.input) == Self.cacheKey(name, clean) }) {
                return ("Already proposed.", false)
            }
            actions.append(PlannedAction(tool: name, input: clean))
            return (Self.proposed, false)
        }
    }

    /// Drives a round-based conversation until the model answers without calling tools.
    func run(_ conversation: ModelConversation, onText: ((String) -> Void)? = nil) async throws -> BrainPlan {
        var finalText = ""
        let known = { Set(self.tools.map(\.name)) }
        for round in 0..<limits.rounds {
            let before = finalText.isEmpty ? "" : finalText + "\n\n"
            var turn = try await conversation.next(tools: tools) { partial in onText?(before + partial) }

            // Small models often write a tool call as JSON in their text instead of calling it.
            if turn.calls.isEmpty, !turn.finished {
                let rescued = Self.extractToolCalls(from: turn.text, knownTools: known())
                if !rescued.calls.isEmpty {
                    turn.text = rescued.text
                    turn.calls = rescued.calls.enumerated().map { ToolCallRequest(id: "text-\(round)-\($0.offset)", name: $0.element.name, input: $0.element.input) }
                }
            }
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { finalText = before + text }
            guard !turn.calls.isEmpty else { break }

            var results: [(call: ToolCallRequest, output: String, isError: Bool)] = []
            for call in turn.calls {
                let result = await handle(name: call.name, input: call.input)
                results.append((call, result.output, result.isError))
            }
            conversation.addResults(results)
            // Only proposals this round and nothing left to look up: the plan is ready.
            if results.allSatisfy({ $0.output == Self.proposed || $0.output == "Already proposed." }) { break }
            if round == limits.rounds - 2 || callCount >= limits.calls {
                conversation.addInstruction(Self.enough)
            }
        }
        return BrainPlan(text: finalText.trimmingCharacters(in: .whitespacesAndNewlines), actions: actions)
    }

    private static func cacheKey(_ name: String, _ input: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return name + ":" + (String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Tool calls written as text

    /// Extracts tool calls formatted as JSON from response text, such as {"name": "list_events", "parameters": {"from": "…"}}.
    /// Returns extracted calls and the cleaned text. Also handles truncated JSON objects (missing closing brace).
    static func extractToolCalls(from text: String, knownTools: Set<String>) -> (text: String, calls: [(name: String, input: [String: Any])]) {
        var remaining = text
        var calls: [(name: String, input: [String: Any])] = []
        var offset = 0  // search offset; String.Index is invalidated after removing substrings

        while offset < remaining.count,
              let open = remaining[remaining.index(remaining.startIndex, offsetBy: offset)...].firstIndex(of: "{") {
            // Match closing brace; if missing, take remaining text and append closing braces.
            var depth = 0, inString = false, escaped = false
            var close: String.Index?
            for index in remaining[open...].indices {
                let character = remaining[index]
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                    continue
                }
                if character == "\"" { inString = true }
                else if character == "{" { depth += 1 }
                else if character == "}" { depth -= 1; if depth == 0 { close = index; break } }
            }
            var candidate = close.map { String(remaining[open...$0]) } ?? (String(remaining[open...]) + String(repeating: "}", count: max(depth, 0)))
            if close == nil, inString { candidate += "\"" + String(repeating: "}", count: max(depth, 0)) }

            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = (object["name"] as? String) ?? (object["tool"] as? String),
                  knownTools.contains(name) else {
                offset = remaining.distance(from: remaining.startIndex, to: open) + 1
                continue
            }
            let input = (object["parameters"] as? [String: Any]) ?? (object["arguments"] as? [String: Any]) ?? (object["input"] as? [String: Any]) ?? [:]
            calls.append((name, input))
            let end = close.map { remaining.index(after: $0) } ?? remaining.endIndex
            offset = remaining.distance(from: remaining.startIndex, to: open)
            remaining.removeSubrange(open..<end)
        }
        // Code fences that held only the call are left empty: remove them.
        remaining = remaining.replacingOccurrences(of: "```(json)?\\s*```", with: "", options: .regularExpression)
        return (remaining.trimmingCharacters(in: .whitespacesAndNewlines), calls)
    }
}
