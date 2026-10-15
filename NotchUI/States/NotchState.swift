import Foundation

enum PanelTab: String, CaseIterable, Identifiable {
    case nook, chat, agents, workspace, connect, music, shelf

    var id: String { rawValue }

    /// Tabs in the notch: Nook (home and chat together), Agents, Workspace (terminals, browser, worktrees), and Music only
    /// while a player is open. Everything you do happens here; configuration lives in Settings.
    @MainActor
    static func visible(musicAvailable: Bool) -> [PanelTab] {
        musicAvailable ? [.chat, .agents, .workspace, .music] : [.chat, .agents, .workspace]
    }

    var title: String {
        switch self {
        case .nook: return tr("tab.nook")
        case .chat: return tr("tab.nook")
        case .agents: return tr("tab.agents")
        case .workspace: return tr("main.workspace")
        case .connect: return tr("tab.connect")
        case .music: return tr("tab.music")
        case .shelf: return tr("tab.shelf")
        }
    }
}

/// A task that opens inside the notch panel, over the current tab, instead of in a separate window.
/// Closed with Back (or Escape); clicking outside the notch does not throw away what you were doing.
enum NotchSheet: Equatable {
    case details(UUID)
    case changes(UUID, file: String?)
    case commit(UUID)
    case pullRequest(UUID)

    var title: String {
        switch self {
        case .details: return tr("agents.run.details")
        case .changes: return tr("ws.changes.title")
        case .commit: return tr("ws.commit.title")
        case .pullRequest: return tr("ws.pr.title")
        }
    }
}

/// What the notch currently displays. Only one state active at a time.
enum NotchState: Equatable {
    case idle                 // idle: Nook on left, counter on right
    case music                // music playing: equalizer bars on right
    case track(title: String, artist: String)   // track started: expands briefly with title
    case done(String)         // recent action, with Undo option
    case card(NookCard)       // a prompt or suggestion
    case nudge(String, NookCard)   // proactive suggestion: short sentence by the notch, hover for full card
    case panel(PanelTab)      // expanded with tabs
}

extension NotchState {
    /// Idle or music: states in which hovering is permitted to open the panel.
    var isResting: Bool {
        switch self {
        case .idle, .music, .track: return true
        default: return false
        }
    }
}

extension NotchState {
    /// Same kind of state (e.g. a different tab within the panel)?
    var kind: String {
        switch self {
        case .idle: return "idle"
        case .music: return "music"
        case .track: return "track"
        case .done: return "done"
        case .card: return "card"
        case .nudge: return "nudge"
        case .panel: return "panel"
        }
    }
}
