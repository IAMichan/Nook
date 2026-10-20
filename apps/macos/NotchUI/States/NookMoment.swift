import Foundation

/// A small moment Nook shares by himself next to the notch (`AppModel+Buddy`): his face in a mood, a short line and
/// at most one button. It goes away by itself; hovering keeps it while you read.
struct NookMoment: Equatable, Identifiable {
    enum Action: Equatable {
        /// Breathe along for a minute: Nook grows and shrinks, the line says when to breathe in and out.
        case breathe
        /// Open the panel at the Nook tab.
        case openNook
        /// Open the panel at the agents.
        case openAgents
    }

    var id: String
    var line: String
    var mood: NookMood
    /// What Nook wears in this moment (a party hat on your birthday); nil for what he wears anyway.
    var outfit: [NookAccessory]?
    var action: Action?
    var actionTitle = ""
    /// How long it stays when you leave it alone.
    var seconds: Double = 12
    /// When it appeared: a breathing moment counts its phases from here.
    var started = Date()

    /// One breathing cycle: 4 seconds in, 4 holding, 6 out (as the orb's `.breathe` pose).
    static let breathCycle: Double = 14
    /// Three cycles, about 40 seconds.
    static let breathLength: Double = breathCycle * 3

    /// The text key for the breathing phase at `elapsed` seconds.
    static func breathPhaseKey(_ elapsed: Double) -> String {
        let c = elapsed.truncatingRemainder(dividingBy: breathCycle)
        if c < 4 { return "buddy.breathe.in" }
        if c < 8 { return "buddy.breathe.hold" }
        return "buddy.breathe.out"
    }
}
