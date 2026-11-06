import Foundation

// Nook's tools for a session on another machine. Its agent reaches them through a socket ssh forwards (`-R`) to a socket of
// its own on this Mac, never to `bridge.sock`: what comes in there speaks for a run on another machine, proved by a token
// made for that run, and gets the tools below only. A machine you run an agent on can use Nook's browser and read its own
// session, but it reaches no other session and can never start anything on this Mac. Foundation only, tested on its own.
enum RemoteBridge {
    static func scriptPath(home: String) -> String { home + "/.nook/nook-mcp" }

    /// Under ~/.nook, which only that user may enter; short, because a socket path has a low limit.
    static func socketPath(home: String, run: UUID) -> String {
        home + "/.nook/b-" + run.uuidString.prefix(8).lowercased() + ".sock"
    }

    /// The ssh arguments that carry the session's socket to this Mac.
    static func forward(socket: String, local: String) -> [String] {
        ["-o", "StreamLocalBindUnlink=yes", "-R", socket + ":" + local]
    }

    /// Puts `script` on the machine and answers with $HOME, or fails when its Perl lacks what the script needs.
    static func setupCommand(script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return #"mkdir -p "$HOME/.nook" && chmod 700 "$HOME/.nook" && printf %s '"# + encoded
            + #"' | { base64 -d 2>/dev/null || base64 -D; } > "$HOME/.nook/nook-mcp" && chmod 755 "$HOME/.nook/nook-mcp""#
            + #" && perl -MJSON::PP -MIO::Socket::UNIX -e 1 && printf %s "$HOME""#
    }

    /// Whether an agent on another machine may use `tool`. Everything that acts on this Mac or in your name stays out.
    static func allows(_ tool: BridgeTool) -> Bool {
        switch tool {
        case .browserOpen, .browserRead, .browserScreenshot, .browserSnapshot, .browserClick, .browserType, .browserWaitFor,
             .renderPage, .sessionRead:
            return true
        case .sessionList, .sessionSearch, .workspaceInfo, .terminalRun, .terminalRead, .terminalList, .terminalStop, .pullRequestCreate,
             .orchestratorCapabilities, .delegateTask, .taskStatus, .taskWait, .taskCancel, .sessionSend, .sessionStart,
             .sessionOrganize, .sessionQuestions, .deviceList, .deviceOpen, .deviceScreenshot, .deviceClose, .scheduleTask,
             .listScheduledTasks, .updateScheduledTask, .runScheduledTaskNow, .watchPullRequest, .getPullRequestStatus,
             .requestSecret, .nookTools, .nookUse, .nookChatList, .nookChatRead, .nookChatSend, .takeOverScreen:
            return false
        }
    }

    /// `session_read` from another machine: its own session only, for what a handoff left out.
    static func mayRead(_ session: String?, caller: UUID) -> Bool {
        session.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } == caller
    }

    static let refusal = "This session runs on another machine: this Nook tool only works for sessions on the Mac. Run commands in your own shell there."

    static let instructions = """
    You are running on another machine over SSH, and the user watches you in Nook on their Mac. Through the `nook` MCP tools \
    you can open pages in Nook's browser on the Mac with browser_open and check them with browser_read, browser_snapshot or \
    browser_screenshot; localhost there is the Mac, not this machine. render_page shows the user a page in your session, and \
    session_read reads your own session. Nook's other tools work only for sessions on the Mac: run commands, dev servers and \
    git in your own shell here.
    """
}
