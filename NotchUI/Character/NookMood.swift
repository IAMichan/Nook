import SwiftUI

/// De stemming van Nook. De ogen en de kleur van de orb volgen hieruit.
enum NookMood: Equatable {
    case rest      // rust: ademt, knippert af en toe
    case seen      // zag iets op je scherm
    case listen    // luistert naar je stem
    case think     // denkt na of plant
    case waiting   // wacht op jouw goedkeuring
    case remind    // herinnert je aan iets
    case worry     // een agent heeft een probleem
    case done      // klaar, tevreden

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
