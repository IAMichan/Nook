import AppKit

extension AppModel {
    /// The connected agents a session in `folder` may use: the ones its project switched off (Settings › Projects) are
    /// left out. Every agent counts the same, Claude Code, Codex, Gemini CLI, Antigravity, OpenCode, Cursor, Grok and
    /// the ACP agents.
    func connectedProviders(in folder: String?) -> [RunProvider] {
        let off = workspace.settings.agentsOff(for: folder)
        guard !off.isEmpty else { return connectedProviders }
        return connectedProviders.filter { !off.contains($0.rawValue) }
    }

    /// Opens a commit an agent named in the session on screen: its Changes tab on that one commit. Resolved in the
    /// session's folder first; a link to a commit this folder does not have opens as a web page (or not at all).
    func openCommitBeside(_ hash: String, folder: String?, fallback: URL?) {
        guard let folder, let git = GitService.shared else {
            if let fallback, !openLinkBeside(fallback) { NSWorkspace.shared.open(fallback) }
            return
        }
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { git.commit(folder, named: hash) }.value
            if let found {
                viewModel.sessionDiffToOpen = .commit(found.id)
            } else if let fallback, !openLinkBeside(fallback) {
                NSWorkspace.shared.open(fallback)
            }
        }
    }
}
