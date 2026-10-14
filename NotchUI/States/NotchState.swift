import Foundation

enum PanelTab: String, CaseIterable, Identifiable {
    case nook, chat, agents, connect, music, shelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nook: return tr("tab.nook")
        case .chat: return tr("tab.chat")
        case .agents: return tr("tab.agents")
        case .connect: return tr("tab.connect")
        case .music: return tr("tab.music")
        case .shelf: return tr("tab.shelf")
        }
    }
}

/// Wat de notch nu toont. Altijd maar één ding tegelijk.
enum NotchState: Equatable {
    case idle                 // rust: Nook links, teller rechts
    case music                // muziek speelt: balkjes rechts
    case track(title: String, artist: String)   // net een nieuw nummer: even breder, met titel
    case done(String)         // net iets gedaan, met Ongedaan maken
    case card(NookCard)       // een vraag of suggestie
    case nudge(String, NookCard)   // Nook denkt mee: een korte zin naast de notch, wijs ernaar voor de hele kaart
    case panel(PanelTab)      // uitgeklapt met tabs
}

extension NotchState {
    /// Rust of muziek: de toestanden waarin hover het paneel mag openen.
    var isResting: Bool {
        switch self {
        case .idle, .music, .track: return true
        default: return false
        }
    }
}

extension NotchState {
    /// Zelfde soort toestand (bijvoorbeeld een andere tab van het paneel)?
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
