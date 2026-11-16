import Foundation

/// Communicates with Antigravity via `agentapi` or the underlying language_server.
enum AntigravityClient {
    struct Command {
        let executable: String
        let baseArguments: [String]
    }

    /// Finds how to invoke `agentapi`.
    static func command() -> Command? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // 1. Direct agentapi helper script in ~/.gemini/antigravity/bin
        let geminiAgentAPI = "\(home)/.gemini/antigravity/bin/agentapi"
        if fm.isExecutableFile(atPath: geminiAgentAPI) {
            return Command(executable: geminiAgentAPI, baseArguments: [])
        }

        // 2. Direct language_server in /Applications/Antigravity.app
        let languageServer = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
        if fm.isExecutableFile(atPath: languageServer) {
            return Command(executable: languageServer, baseArguments: ["agentapi"])
        }

        // 3. Antigravity IDE app bundle
        let ideLanguageServer = "/Applications/Antigravity IDE.app/Contents/Resources/bin/language_server"
        if fm.isExecutableFile(atPath: ideLanguageServer) {
            return Command(executable: ideLanguageServer, baseArguments: ["agentapi"])
        }

        // 4. Other known locations
        let candidates = [
            "\(home)/.antigravity/antigravity/bin/agentapi",
            "\(home)/.antigravity-ide/antigravity-ide/bin/agentapi",
            "\(home)/.local/bin/agentapi",
            "/opt/homebrew/bin/agentapi",
            "/usr/local/bin/agentapi"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return Command(executable: path, baseArguments: [])
        }

        return nil
    }

    static var isAvailable: Bool {
        command() != nil
    }

    /// Sends a message into an existing conversation.
    static func sendMessage(conversationID: String, message: String) async throws {
        guard let cmd = command() else {
            throw NookError("Antigravity is not installed or agentapi could not be found.")
        }

        try await Task.detached(priority: .userInitiated) {
            // Both pipes are drained at once (a process that writes more than a pipe holds would block otherwise), and a
            // deadline keeps a hanging agentapi from holding the send for good.
            let result: ProcessRunner.Output
            do {
                result = try ProcessRunner.run(cmd.executable, cmd.baseArguments + ["send-message", conversationID, message],
                                               timeout: 120)
            } catch {
                throw NookError(error.localizedDescription)
            }

            if result.status != 0 || result.timedOut {
                var errorMsg = ""
                if let json = try? JSONSerialization.jsonObject(with: result.stdoutData) as? [String: Any],
                   let err = json["error"] as? String, !err.isEmpty {
                    errorMsg = err
                } else {
                    let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !err.isEmpty { errorMsg = err }
                }
                throw NookError(errorMsg.isEmpty ? "Antigravity process exited with code \(result.status)" : errorMsg)
            }
        }.value
    }
}
