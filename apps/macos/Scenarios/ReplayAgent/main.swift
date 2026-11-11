// The replay agent: a stand-in for Claude Code that the scenarios install as `claude` in the scenario home. It speaks
// the part of `claude -p --input-format stream-json --output-format stream-json` that Nook reads (ClaudeStreamParser):
// for every user message on stdin it plays the next recorded turn of a recording (Scenarios/Recordings/<name>.jsonl),
// with small delays so the reply streams. It never talks to a model and never reads the user's files.
//
// Recording format, one JSON object per line (blank lines and lines starting with // are skipped):
//   {"replay":"turn"}                                   starts the next turn (the first one is implicit)
//   {"replay":"text","text":"…","chunk":8,"ms":40}      streams text as deltas, then the full assistant message
//   {"replay":"tool","id":"t1","name":"Read","input":{…},"result":"…","ms":300}
//                                                       a tool call and, after `ms`, its result
//   {"replay":"sleep","ms":500}                         waits
//   any other object                                    is written as is (a raw stream-json line)
// Placeholders in strings: {{cwd}}, {{session_id}}, {{model}}, {{turn}}, {{uuid}} (a new one each time).
// Each turn starts with a system init line and ends with a result line, unless the recording writes its own result.
//
// The recording is the session's model (`--model showcase`), "showcase" when none is given. Environment:
//   NOOK_REPLAY_RECORDINGS  folder with the recordings (required)
//   NOOK_REPLAY_STATE       folder for the turn counter per conversation and the launch log (required)
//   NOOK_REPLAY_SPEED       delay factor, 1 by default (0 plays without waiting)
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func argument(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--version") || arguments.contains("-v") {
    print("2.0.0 (Claude Code replay)")
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    // No --thinking-display: Nook then leaves that flag out.
    print("Usage: claude [options] [prompt]\n\nNook scenario replay agent: plays recorded turns, never calls a model.")
    exit(0)
}

guard let recordingsPath = environment["NOOK_REPLAY_RECORDINGS"], let statePath = environment["NOOK_REPLAY_STATE"] else {
    FileHandle.standardError.write(Data("replay agent: NOOK_REPLAY_RECORDINGS and NOOK_REPLAY_STATE must be set\n".utf8))
    exit(2)
}
let speed = Double(environment["NOOK_REPLAY_SPEED"] ?? "") ?? 1
let model = argument("--model").flatMap { $0.isEmpty ? nil : $0 } ?? "showcase"
let sessionID = argument("--resume") ?? UUID().uuidString.lowercased()
let cwd = FileManager.default.currentDirectoryPath
let stateDirectory = URL(fileURLWithPath: statePath, isDirectory: true)
try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)

/// One line per launch, so the harness can prove that this program, and no real agent, answered.
func log(_ line: String) {
    let url = stateDirectory.appendingPathComponent("launches.log")
    let entry = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(entry)
        try? handle.close()
    } else {
        try? entry.write(to: url)
    }
}
log("pid=\(getpid()) model=\(model) session=\(sessionID) cwd=\(cwd) args=\(arguments.count)")

// MARK: Recording

let recordingURL = URL(fileURLWithPath: recordingsPath).appendingPathComponent(model + ".jsonl")
guard let recordingText = try? String(contentsOf: recordingURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("replay agent: no recording named \(model) in \(recordingsPath)\n".utf8))
    exit(2)
}
var turns: [[[String: Any]]] = [[]]
for raw in recordingText.split(separator: "\n", omittingEmptySubsequences: true) {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty || line.hasPrefix("//") { continue }
    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        FileHandle.standardError.write(Data("replay agent: \(model).jsonl has a line that is not a JSON object: \(line)\n".utf8))
        exit(2)
    }
    if object["replay"] as? String == "turn" {
        if !(turns.last ?? []).isEmpty { turns.append([]) }
    } else {
        turns[turns.count - 1].append(object)
    }
}

// MARK: Output

let outputLock = NSLock()
func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    outputLock.lock()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    outputLock.unlock()
}

let interruptLock = NSLock()
var interrupted = false
func isInterrupted() -> Bool { interruptLock.lock(); defer { interruptLock.unlock() }; return interrupted }
func setInterrupted(_ value: Bool) { interruptLock.lock(); interrupted = value; interruptLock.unlock() }

func pause(_ milliseconds: Double) {
    let seconds = milliseconds * speed / 1000
    guard seconds > 0 else { return }
    // In small steps, so an interrupt ends the turn quickly.
    let end = Date().addingTimeInterval(seconds)
    while Date() < end, !isInterrupted() { Thread.sleep(forTimeInterval: min(0.02, end.timeIntervalSinceNow)) }
}

func substitute(_ value: Any, turn: Int) -> Any {
    switch value {
    case let text as String:
        var result = text
            .replacingOccurrences(of: "{{cwd}}", with: cwd)
            .replacingOccurrences(of: "{{session_id}}", with: sessionID)
            .replacingOccurrences(of: "{{model}}", with: model)
            .replacingOccurrences(of: "{{turn}}", with: String(turn))
        while let range = result.range(of: "{{uuid}}") { result.replaceSubrange(range, with: UUID().uuidString.lowercased()) }
        return result
    case let array as [Any]: return array.map { substitute($0, turn: turn) }
    case let dictionary as [String: Any]: return dictionary.mapValues { substitute($0, turn: turn) }
    default: return value
    }
}

let usage: [String: Any] = ["input_tokens": 12, "output_tokens": 24, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]

func assistant(_ content: [[String: Any]]) -> [String: Any] {
    ["type": "assistant", "parent_tool_use_id": NSNull(), "session_id": sessionID, "uuid": UUID().uuidString.lowercased(),
     "message": ["id": "msg_" + UUID().uuidString.lowercased(), "type": "message", "role": "assistant", "model": "replay-" + model,
                 "content": content, "usage": usage]]
}

func streamEvent(_ event: [String: Any]) -> [String: Any] {
    ["type": "stream_event", "parent_tool_use_id": NSNull(), "session_id": sessionID, "uuid": UUID().uuidString.lowercased(),
     "event": event]
}

/// Plays one turn and returns the reply text it wrote (for the result line).
func play(_ entries: [[String: Any]], turn: Int) {
    let started = Date()
    emit(["type": "system", "subtype": "init", "session_id": sessionID, "model": "replay-" + model, "cwd": cwd,
          "tools": ["Read", "Edit", "Bash", "Grep"], "mcp_servers": [], "permissionMode": "default",
          "uuid": UUID().uuidString.lowercased()])
    var reply = ""
    var wroteResult = false
    for raw in entries {
        if isInterrupted() { break }
        let entry = substitute(raw, turn: turn) as? [String: Any] ?? [:]
        switch entry["replay"] as? String {
        case "sleep":
            pause((entry["ms"] as? Double) ?? 300)
        case "text":
            let text = (entry["text"] as? String) ?? ""
            let chunk = max(1, (entry["chunk"] as? Int) ?? 6)
            let gap = (entry["ms"] as? Double) ?? 35
            emit(streamEvent(["type": "message_start", "message": ["id": "msg_" + UUID().uuidString.lowercased(), "usage": usage]]))
            emit(streamEvent(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]))
            var rest = Substring(text)
            while !rest.isEmpty, !isInterrupted() {
                // Whole words where it can, so the text grows as a model writes it.
                var piece = rest.prefix(chunk)
                if piece.count == chunk, let space = rest.dropFirst(chunk).firstIndex(of: " ") {
                    piece = rest[rest.startIndex..<space]
                }
                rest = rest.dropFirst(piece.count)
                emit(streamEvent(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": String(piece)]]))
                pause(gap)
            }
            emit(streamEvent(["type": "content_block_stop", "index": 0]))
            emit(assistant([["type": "text", "text": text]]))
            reply = text
        case "tool":
            let id = (entry["id"] as? String) ?? "toolu_" + UUID().uuidString.lowercased()
            emit(assistant([["type": "tool_use", "id": id, "name": (entry["name"] as? String) ?? "Read",
                             "input": entry["input"] ?? [String: Any]()]]))
            pause((entry["ms"] as? Double) ?? 300)
            emit(["type": "user", "parent_tool_use_id": NSNull(), "session_id": sessionID, "uuid": UUID().uuidString.lowercased(),
                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id,
                                                            "content": (entry["result"] as? String) ?? "",
                                                            "is_error": (entry["error"] as? Bool) ?? false]]]])
        default:
            if entry["type"] as? String == "result" { wroteResult = true }
            pause(60)
            emit(entry)
        }
    }
    guard !wroteResult else { return }
    let stopped = isInterrupted()
    emit(["type": "result", "subtype": stopped ? "error_during_execution" : "success", "is_error": stopped,
          "duration_ms": Int(Date().timeIntervalSince(started) * 1000), "num_turns": 1, "result": reply,
          "session_id": sessionID, "total_cost_usd": 0, "usage": usage,
          "terminal_reason": stopped ? "aborted_streaming" : "completed", "uuid": UUID().uuidString.lowercased()])
}

/// The next turn of this conversation: the counter lives on disk, so a resumed conversation goes on where it was.
func nextTurn() -> Int {
    let url = stateDirectory.appendingPathComponent("turn-" + sessionID)
    let turn = Int((try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    try? String(turn + 1).write(to: url, atomically: true, encoding: .utf8)
    return turn
}

// MARK: Input

let pending = DispatchSemaphore(value: 0)
let queueLock = NSLock()
var queued: [String] = []
var inputClosed = false

let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        switch object["type"] as? String {
        case "user":
            let message = object["message"] as? [String: Any]
            let text = (message?["content"] as? String) ?? ""
            queueLock.lock(); queued.append(text); queueLock.unlock()
            pending.signal()
        case "control_request":
            let id = (object["request_id"] as? String) ?? ""
            let request = object["request"] as? [String: Any]
            if request?["subtype"] as? String == "interrupt" { setInterrupted(true) }
            emit(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": [String: Any]()]])
        default:
            break
        }
    }
    queueLock.lock(); inputClosed = true; queueLock.unlock()
    pending.signal()
}
reader.start()

while true {
    pending.wait()
    queueLock.lock()
    let next = queued.isEmpty ? nil : queued.removeFirst()
    let closed = inputClosed
    queueLock.unlock()
    guard next != nil else {
        if closed { exit(0) }
        continue
    }
    setInterrupted(false)
    let turn = nextTurn()
    if turn < turns.count {
        play(turns[turn], turn: turn)
    } else {
        play([["replay": "text", "text": "Replay \(model): no more recorded turns."]], turn: turn)
    }
}
