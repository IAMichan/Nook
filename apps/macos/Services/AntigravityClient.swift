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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmd.executable)
            process.arguments = cmd.baseArguments + ["send-message", conversationID, message]
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw NookError(error.localizedDescription)
            }

            // Both pipes are drained before waiting: a process that writes more than a pipe holds (64 KB) would otherwise
            // block on the write while Nook blocks on its exit, for good.
            let errors = PipeDrain(stderr)
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = errors.wait()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                var errorMsg = ""
                if let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                   let err = json["error"] as? String, !err.isEmpty {
                    errorMsg = err
                } else if let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !err.isEmpty {
                    errorMsg = err
                }
                throw NookError(errorMsg.isEmpty ? "Antigravity process exited with code \(process.terminationStatus)" : errorMsg)
            }
        }.value
    }
}

/// Reads a pipe to its end on another thread, so a second pipe of the same process can be read at the same time.
private final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}
