import Foundation

/// MCP apps in a session (see McpApp): Codex fetches the page of a tool call that has one, and later runs the tools
/// and reads the resources the page asks for, on the same thread; nothing starts a turn. What a page tells the agent
/// goes along with the next turn.
extension WorkspaceManager {
    private static let mcpAppCaptureSeconds: UInt64 = 20

    /// Where app pages are kept: one folder per session, removed with it.
    static func mcpAppFolder(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/McpApps/\(id.uuidString.lowercased())", isDirectory: true)
    }

    // MARK: Capture

    /// Reads the app's page through Codex (`mcpServer/resource/read`), saves it with its Content-Security-Policy and puts
    /// the reference on the tool call. Any failure leaves a plain tool row.
    func captureMcpApp(_ id: UUID, _ client: CodexAppServerClient, callID: String, server: String, tool: String,
                       arguments: String?, result: String?, resourceUri: String) {
        guard let thread = client.threadID else { return }
        Task { [weak self] in
            let response = try? await Self.codexRequest(client, "mcpServer/resource/read",
                                                        ["threadId": thread, "server": server, "uri": resourceUri],
                                                        timeout: Self.mcpAppCaptureSeconds)
            guard let self, let contents = response?["contents"] as? [Any],
                  let document = McpApp.document(contents: contents, uri: resourceUri) else { return }
            let folder = Self.mcpAppFolder(id)
            let file = folder.appendingPathComponent(UUID().uuidString.lowercased() + ".html")
            let saved = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data(McpApp.prepared(document.html, csp: document.csp).utf8).write(to: file, options: .atomic)
                    return true
                } catch {
                    return false
                }
            }.value
            guard saved else { return }
            let reference = McpApp.Reference(file: file.path, server: server, tool: tool, resourceUri: resourceUri, csp: document.csp,
                                             permissions: document.permissions, prefersBorder: document.prefersBorder,
                                             arguments: arguments, result: result)
            guard let eventID = self.turns[id]?.toolEvents[callID] ?? self.timeline(id).last(where: { $0.callID == callID })?.id else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            self.mutateEvent(id, eventID) { event in
                event.output = McpUI.encode(app: reference, resultText: McpUI.stripped(event.output ?? ""))
            }
        }
    }

    // MARK: What a page asks for

    /// The server's tool as Codex lists it: whether the page may call it, and whether it only reads.
    func mcpAppToolInfo(_ id: UUID, server: String, name: String) async throws -> (callable: Bool, readOnly: Bool, title: String?) {
        let (client, thread) = try codexForApp(id)
        let response = try await Self.codexRequest(client, "mcpServerStatus/list",
                                                   ["threadId": thread, "serverName": server, "detail": "toolsAndAuthOnly"], timeout: 30)
        let entry = ((response["data"] as? [[String: Any]]) ?? []).first { ($0["name"] as? String) == server }
        let tools: [[String: Any]]
        if let map = entry?["tools"] as? [String: Any] {
            tools = map.values.compactMap { $0 as? [String: Any] }
        } else {
            tools = (entry?["tools"] as? [[String: Any]]) ?? []
        }
        guard let tool = tools.first(where: { ($0["name"] as? String) == name }) else { return (false, false, nil) }
        let annotations = tool["annotations"] as? [String: Any]
        return (McpApp.callableByApp(meta: tool["_meta"]), (annotations?["readOnlyHint"] as? Bool) == true, annotations?["title"] as? String)
    }

    /// Runs the tool on the server through Codex (`mcpServer/tool/call`). Checked again here: a hidden tool is refused.
    func mcpAppCallTool(_ id: UUID, server: String, name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let info = try await mcpAppToolInfo(id, server: server, name: name)
        guard info.callable else { throw McpAppHost.Refusal(message: tr("ws.mcpApp.notCallable", name)) }
        let (client, thread) = try codexForApp(id)
        return try await Self.codexRequest(client, "mcpServer/tool/call",
                                           ["threadId": thread, "server": server, "tool": name, "arguments": arguments], timeout: 120)
    }

    func mcpAppReadResource(_ id: UUID, server: String, uri: String) async throws -> [String: Any] {
        let (client, thread) = try codexForApp(id)
        let response = try await Self.codexRequest(client, "mcpServer/resource/read", ["threadId": thread, "server": server, "uri": uri], timeout: 30)
        return ["contents": (response["contents"] as? [Any]) ?? []]
    }

    /// What the page wants the agent to know on its next turn; nil clears it.
    func mcpAppSetContext(_ id: UUID, key: String, text: String?) {
        var contexts = mcpAppContexts[id] ?? [:]
        contexts[key] = text
        mcpAppContexts[id] = contexts.isEmpty ? nil : contexts
    }

    /// A message the page sends as you (after you agreed): now, or after the running turn.
    func mcpAppSendMessage(_ id: UUID, text: String) {
        guard let run = run(id) else { return }
        if run.canContinue, processes[id] == nil, !run.status.isActive { send(id, text: text) } else { enqueue(id, text: text) }
    }

    /// The app contexts that go with the turn starting now (and are then cleared): Codex takes them as
    /// `additionalContext`, the other agents as a block ahead of the message.
    func takeMcpAppContexts(_ id: UUID) -> [(key: String, text: String)] {
        guard let contexts = mcpAppContexts.removeValue(forKey: id) else { return [] }
        return contexts.keys.sorted().map { (key: "mcp_app_" + $0, text: contexts[$0] ?? "") }
    }

    /// The session a timeline event belongs to.
    func runID(containing eventID: UUID) -> UUID? {
        events.first { $0.value.contains { $0.id == eventID } }?.key
    }

    // MARK: Helpers

    private func codexForApp(_ id: UUID) throws -> (CodexAppServerClient, String) {
        guard let client = codexServers[id], client.isRunning, let thread = client.threadID else {
            throw McpAppHost.Refusal(message: tr("ws.mcpApp.sessionStopped"))
        }
        return (client, thread)
    }

    /// One app-server request as async, given up after `timeout` seconds (a server that hangs must not hold the page).
    static func codexRequest(_ client: CodexAppServerClient, _ method: String, _ params: [String: Any],
                             timeout: UInt64) async throws -> [String: Any] {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            client.request(method, params) { result in
                once.run {
                    switch result {
                    case .success(let box): continuation.resume(returning: box.dictionary)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeout))) {
                once.run { continuation.resume(throwing: McpAppHost.Refusal(message: tr("ws.mcpApp.timeout"))) }
            }
        }
    }
}

/// Lets only the first of several callbacks through.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
