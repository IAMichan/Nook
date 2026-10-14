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

/// Een keuzemogelijkheid bij een vraag van een agent.
struct ChoiceOption: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var description: String
}

/// Een vraag met opties. `id` verwijst naar een handler die `NotchViewModel.choose` aanroept.
struct ChoiceSet: Equatable {
    var id: String
    var options: [ChoiceOption]
    var multiSelect: Bool
}

/// Eén regel in een overzicht, bijvoorbeeld "Tijd met agents · 6 u 12 min".
struct Fact: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var value: String
}

enum CardDetail: Equatable {
    case none
    case event(top: String, big: String, line: String, subline: String)
    case command(String, note: String)
    case waveform
    case steps([PlanStep])
    case choices(ChoiceSet)
    case diff(title: String, lines: [DiffLine], note: String)
    case facts([Fact])
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
    /// Extra rustige knoppen naast de twee vaste (bijvoorbeeld "Altijd" en "In terminal").
    var extra: [CardAction] = []
    /// Een agent wacht hierop (toestemming of vraag): de kaart gaat voor alles en blijft tot je antwoordt.
    var urgent: Bool = false
    /// Waar Nook naar keek voor dit antwoord ("3 vensters", "Agenda", "GitHub"), als kleine labels onder de context.
    var sources: [String] = []
    /// Wat Nook hierna voor je kan doen ("Zet het in mijn agenda"). Een klik stuurt de zin als nieuw verzoek.
    var offers: [String] = []
    /// Wat Esc doet. Zonder waarde: de hoofdknop.
    var escape: CardAction? = nil
}
