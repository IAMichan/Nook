import Foundation

/// De kaarten die Nook kan tonen. Elke kaart: één zin, één detailregel, hooguit twee knoppen.
enum CardScene: String, Equatable {
    case suggestion, reminder, listening, plan, approval
}

enum CardOutcome: Equatable {
    case done(String)       // uitgevoerd: toon een korte bevestiging met Ongedaan maken
    case show(CardScene)    // ga door naar een volgende kaart
    case dismiss            // terug naar rust
    case callback(String, String)  // voer een geregistreerde actie uit; tweede waarde is de bevestiging (leeg = niets tonen)
}

struct CardAction: Equatable {
    var label: String
    var outcome: CardOutcome
}

enum StepTone: Equatable {
    case good, neutral, caution
}

struct PlanStep: Equatable, Identifiable {
    var id: Int { number }
    var number: Int
    var text: String
    var tag: String
    var tone: StepTone
}

enum CardDetail: Equatable {
    case none
    case event(top: String, big: String, line: String, subline: String)
    case command(String, note: String)
    case waveform
    case steps([PlanStep])
}

struct NookCard: Equatable, Identifiable {
    var id: String
    var mood: NookMood
    var context: String
    var title: String
    var detail: CardDetail
    var primary: CardAction
    var secondary: CardAction
    /// Hoogte van de inhoud onder de notch, zonder marges.
    var contentHeight: CGFloat
    /// Toont een tekstveld om meteen door te vragen. Het veld heeft de focus zodra de kaart verschijnt.
    var input: Bool = false
}
