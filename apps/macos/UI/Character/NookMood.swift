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
    // The friend side of Nook: shown in the moments he shares with you (`AppModel+Buddy`).
    case proud     // something you did went well: chin up, a little bounce
    case curious   // something new: head tilted, one eye wider
    case cozy      // a quiet, warm moment: soft eyes, blush, swaying
    case focus     // working along with you: narrow eyes, steady
    case surprised // unexpected good news: wide eyes, a little jump
    case caring    // a hard moment: soft, sympathetic eyes
    case sleepy    // late at night: eyes shut, slow breathing
    case celebrate // a party: happy eyes, hops and sparks
    case breathe   // breathing along with you: grows and shrinks in 4-4-6

    var color: Color {
        switch self {
        case .rest, .seen, .think, .curious, .focus, .surprised, .sleepy: return NookTheme.iris
        case .listen, .done, .proud, .celebrate: return NookTheme.mint
        case .breathe: return NookTheme.mintSoft
        case .waiting, .remind, .cozy: return NookTheme.amber
        case .worry: return NookTheme.coral
        case .caring: return NookTheme.coralSoft
        }
    }

    var label: String {
        switch self {
        case .rest: return "Nook"
        case .seen: return tr("nook.mood.seen")
        case .listen: return tr("nook.mood.listen")
        case .think: return tr("nook.mood.think")
        case .waiting: return tr("nook.mood.waiting")
        case .remind: return tr("nook.mood.remind")
        case .worry: return tr("nook.mood.worry")
        case .done: return tr("nook.mood.done")
        case .proud: return tr("nook.mood.proud")
        case .curious: return tr("nook.mood.curious")
        case .cozy: return tr("nook.mood.cozy")
        case .focus: return tr("nook.mood.focus")
        case .surprised: return tr("nook.mood.surprised")
        case .caring: return tr("nook.mood.caring")
        case .sleepy: return tr("nook.mood.sleepy")
        case .celebrate: return tr("nook.mood.celebrate")
        case .breathe: return tr("nook.mood.breathe")
        }
    }

    /// Happy ^ ^ eyes instead of open ones.
    var smiles: Bool { self == .done || self == .proud || self == .celebrate || self == .cozy }

    /// Eyes stay shut: no blinking.
    var eyesShut: Bool { self == .sleepy || self == .breathe }
}
