import SwiftUI

/// What Nook knows about one agent session it sees through hooks or the process list.
enum AgentStatus: Equatable {
    case waiting, running, failed, done
    case detected   // running on this Mac, but not yet linked with hooks

    var label: String {
        switch self {
        case .detected: return tr("agents.status.detected")
        case .waiting: return tr("agents.status.waiting")
        case .running: return tr("agents.status.running")
        case .failed: return tr("agents.status.failed")
        case .done: return tr("agents.status.done")
        }
    }

    var color: Color {
        switch self {
        case .detected: return NookTheme.textSecondary
        case .waiting: return NookTheme.amber
        case .running: return NookTheme.iris
        case .failed: return NookTheme.coral
        case .done: return NookTheme.mint
        }
    }
}

struct AgentStep: Identifiable, Equatable {
    enum Mark: Equatable { case done, running, blocked, failed, todo }
    let id = UUID()
    var mark: Mark
    var text: String

    var symbol: String {
        switch mark {
        case .done: return "✓"
        case .running: return "◐"
        case .blocked: return "●"
        case .failed: return "✗"
        case .todo: return "○"
        }
    }

    var color: Color {
        switch mark {
        case .done: return NookTheme.mint
        case .running: return NookTheme.iris
        case .blocked: return NookTheme.amber
        case .failed: return NookTheme.coral
        case .todo: return NookTheme.textTertiary
        }
    }
}

struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case add, remove, context }
    let id = UUID()
    var kind: Kind
    var text: String

    var color: Color {
        switch kind {
        case .add: return NookTheme.mintSoft
        case .remove: return NookTheme.coralSoft
        case .context: return NookTheme.textTertiary
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    var id: String
    var name: String
    var project: String
    var status: AgentStatus
    var file: String
    var placeholder: String
    var steps: [AgentStep]
    var diff: [DiffLine]
    /// Working directory of the session.
    var cwd: String = ""
    /// The host app where the agent is running (Terminal, iTerm, VS Code...), for "Open terminal".
    var hostBundleID: String = ""
    /// The account directory (CLAUDE_CONFIG_DIR, CODEX_HOME); empty for the default account.
    var home: String = ""
    /// A request currently awaiting your response.
    var approvalID: String? = nil
    /// Added and removed lines in this session.
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    /// A single-sentence summary of the agent's last response or message.
    var summary: String = ""
    /// Detected processes only: the agent is linked, but this session started prior to linking.
    var isLinked: Bool = false
    /// The agent's own session id (hooks only); needed to continue the conversation.
    var sessionID: String = ""
    /// Path of the session's transcript, so Nook can show the conversation.
    var transcriptPath: String = ""
    /// The last thing you asked, in full.
    var lastPrompt: String = ""
    /// The agent's last reply, in full.
    var lastReply: String = ""
    /// When the session started, as far as Nook knows.
    var started: Date? = nil
    /// Derived from a running process rather than hooks.
    var isDetected: Bool { status == .detected }
}
