import SwiftUI

/// Nook's mood. Determines eye shape and orb color.
enum NookMood: Equatable {
    case rest      // idle: breathing, occasional blink
    case seen      // noticed something on your screen
    case listen    // listening to your voice
    case think     // thinking or planning
    case waiting   // awaiting your approval
    case remind    // reminding you of something
    case worry     // an agent ran into an issue
    case done      // finished, content

    var color: Color {
        switch self {
        case .rest, .seen, .think: return NookTheme.iris
        case .listen, .done: return NookTheme.mint
        case .waiting, .remind: return NookTheme.amber
        case .worry: return NookTheme.coral
        }
    }

    var label: String {
        switch self {
        case .rest: return "Nook"
        case .seen: return "zag iets"
        case .listen: return "luistert"
        case .think: return "denkt mee"
        case .waiting: return "wacht op jou"
        case .remind: return "herinnert"
        case .worry: return "let op"
        case .done: return "klaar"
        }
    }
}
