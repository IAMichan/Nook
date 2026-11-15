import Foundation

enum PanelTab: String, CaseIterable, Identifiable {
    case nook, chat, agents, inbox, connect, music, shelf

    var id: String { rawValue }

    /// The panel's tabs, in the main window and the notch alike: Nook (home and chat together), Agents, Chats (every chat app in one inbox), and Music once
    /// there is something to show (`NowPlayingService.hasMusic`). Terminals, the browser and worktrees live with the agents that use them. Everything you
    /// do happens here; configuration lives in Settings.
    @MainActor
    static func visible(musicAvailable: Bool) -> [PanelTab] {
        musicAvailable ? [.chat, .agents, .inbox, .music] : [.chat, .agents, .inbox]
    }

    var title: String {
        switch self {
        case .nook: return tr("tab.nook")
        case .chat: return tr("tab.nook")
        case .agents: return tr("tab.agents")
        case .inbox: return tr("tab.chats")
        case .connect: return tr("tab.connect")
        case .music: return tr("tab.music")
        case .shelf: return tr("tab.shelf")
        }
    }
}

/// A task that opens inside the panel, over the current tab, instead of in a separate window.
/// Closed with Back (or Escape); clicking outside the panel does not throw away what you were doing.
enum PanelSheet: Equatable {
    case details(UUID)
    case changes(UUID, file: String?)
    case commit(UUID)
    case pullRequest(UUID)
    /// The changes in the folder of a session Nook does not run itself.
    case folderChanges(String)
    /// Commit and pull request in the repository of a session Nook does not run itself, by its root.
    case folderCommit(String)
    case folderPullRequest(String)

    var title: String {
        switch self {
        case .details: return tr("agents.run.details")
        case .changes: return tr("ws.changes.title")
        case .commit: return tr("ws.commit.title")
        case .pullRequest: return tr("ws.pr.title")
        case .folderChanges: return tr("ws.changes.title")
        case .folderCommit: return tr("ws.commit.title")
        case .folderPullRequest: return tr("ws.pr.title")
        }
    }
}
