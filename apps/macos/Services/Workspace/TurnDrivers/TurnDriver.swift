import Foundation

/// How a turn reaches one family of coding agents. `WorkspaceManager` stays the facade (`launchTurn`, `stop`, `prewarm`,
/// `decide`): it does what every agent shares and hands the rest to the driver of the session's family, which is chosen
/// from the agent's capabilities (`turnFamily(for:executable:)`).
@MainActor
protocol TurnDriver {
    var workspace: WorkspaceManager { get }
    /// Starts the turn once the shared preparation in `launchTurn` is done.
    func launch(_ id: UUID, prompt: String, executable: String, showPrompt: Bool)
    /// Opens the session's idle connection ahead of your first message (`WorkspaceManager.prewarm`).
    func prewarm(_ id: UUID, run: WorkspaceRun, executable: String)
    /// Stops the running turn. False when nothing of this family runs for the session.
    func stop(_ id: UUID) -> Bool
    /// Answers a permission request. False when it is not one of this family's.
    func decide(_ runID: UUID, requestID: String, _ decision: WorkspaceManager.Decision, reason: String) -> Bool
}

/// The ways Nook runs a turn: a process per turn that speaks a channel on stdin (Claude Code's stream-json, Pi's RPC) or
/// none (`codex exec`, Gemini CLI's headless mode), or a client that stays connected (Codex's app-server, OpenCode's own
/// server, ACP).
enum TurnFamily: CaseIterable, Sendable {
    case claudeStreamJSON, piRPC, exec, codexAppServer, openCodeServer, acp
}

extension WorkspaceManager {
    /// The family a turn of this session goes through with this executable. Codex speaks app-server when it can, OpenCode
    /// its own server when the installed one has it (else ACP, `openCodeFallback`); an ACP agent falls back to its
    /// headless mode when its ACP server failed (`acpFallback`); every other turn is a process, told apart by the channel
    /// it listens on.
    func turnFamily(for run: WorkspaceRun, executable: String) -> TurnFamily {
        if usesCodexServer(run, executable) { return .codexAppServer }
        if usesOpenCodeServer(run, executable) { return .openCodeServer }
        if run.provider.usesACP, !acpFallback.contains(executable) { return .acp }
        return processTurnFamily(run.provider.capabilities.processChannel)
    }

    func processTurnFamily(_ channel: ProcessChannel) -> TurnFamily {
        switch channel {
        case .claudeStreamJSON: return .claudeStreamJSON
        case .piRPC: return .piRPC
        case .none: return .exec
        }
    }

    func turnDriver(_ family: TurnFamily) -> TurnDriver {
        switch family {
        case .claudeStreamJSON: return ClaudeStreamTurnDriver(workspace: self)
        case .piRPC: return PiRPCTurnDriver(workspace: self)
        case .exec: return ExecTurnDriver(workspace: self)
        case .codexAppServer: return CodexServerTurnDriver(workspace: self)
        case .openCodeServer: return OpenCodeServerTurnDriver(workspace: self)
        case .acp: return AcpTurnDriver(workspace: self)
        }
    }

    func turnDriver(for run: WorkspaceRun, executable: String) -> TurnDriver {
        turnDriver(turnFamily(for: run, executable: executable))
    }

    /// The driver of a session's turn process (when it runs one): by the channel its agent listens on.
    func processTurnDriver(_ id: UUID) -> ProcessTurnDriver {
        switch processTurnFamily(run(id)?.provider.capabilities.processChannel ?? ProcessChannel.none) {
        case .claudeStreamJSON: return ClaudeStreamTurnDriver(workspace: self)
        case .piRPC: return PiRPCTurnDriver(workspace: self)
        case .exec, .codexAppServer, .openCodeServer, .acp: return ExecTurnDriver(workspace: self)
        }
    }

    /// The drivers that keep a client connected between turns, in the order a stop or an answer tries them: each one
    /// only acts on what it has open for the session (or on a request it asked).
    var connectedTurnDrivers: [TurnDriver] {
        [CodexServerTurnDriver(workspace: self), OpenCodeServerTurnDriver(workspace: self), AcpTurnDriver(workspace: self)]
    }
}
