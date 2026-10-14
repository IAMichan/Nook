import Foundation

enum PanelTab: String, CaseIterable, Identifiable {
    case today, agents, music, shelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Vandaag"
        case .agents: return "Agents"
        case .music: return "Muziek"
        case .shelf: return "Shelf"
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
        case .panel: return "panel"
        }
    }
}
