import Foundation

/// What the notch currently displays. Only one state active at a time.
enum NotchState: Equatable {
    case idle                 // idle: Nook on left, counter on right
    case music                // music playing: equalizer bars on right
    case track(title: String, artist: String)   // track started: expands briefly with title
    case done(String)         // recent action, with Undo option
    case card(NookCard)       // a prompt or suggestion
    case nudge(String, NookCard)   // proactive suggestion: short sentence by the notch, hover for full card
    case moment(NookMoment)   // a friendly moment Nook shares by himself: good morning, a break, a celebration
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
        case .moment: return "moment"
        case .panel: return "panel"
        }
    }
}
