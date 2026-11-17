import Foundation

// The choices of Nook's own composer on the phone (`CompanionFeature.nookComposer`), as the Mac's Nook tab offers them
// under its box: the model Nook thinks with (`BrainChip`), what Nook may do by itself (`NookAccessMenu`) and the sources
// it reads (`ScopeMenu`). The phone asks for them (`nookComposer`, with `conversation` for an open chat) and changes
// one at a time (`nookComposerSet`: `text` the kind, `item` the choice's id, `allow` on or off); every change needs the
// *operate* scope, is checked again by the Mac and logged as `companion_nook_composer`.

/// What Nook's composer shows and offers now.
struct NookComposerDigest: Codable, Equatable, Sendable {
    /// One choice in a list: a model, an access level, a source.
    struct Choice: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var detail: String? = nil
        /// The heading it is listed under: the agent it thinks through ("Claude Code"), or "On this Mac".
        var group: String? = nil
        var chosen: Bool
        /// Shown, but changed on the Mac only (Nook's widest access).
        var macOnly: Bool? = nil
    }

    /// The model's pill ("Claude Code · Opus"), and the models to pick from, grouped by where they run.
    var model: String
    var models: [Choice]
    /// What Nook may do by itself (`NookAccess`): the chosen level's id, and the levels.
    var access: String
    var accesses: [Choice]
    /// The sources' pill ("Automatic", or the ones you limited it to) and whether you limited them.
    var scope: String
    var restricted: Bool
    /// The sources Nook can be limited to ("Only these"): `chosen` is on for each one it is limited to.
    var only: [Choice]
    /// The sources Nook never reads (the screen, the web, the clipboard): `chosen` is on for each one left out.
    var never: [Choice]

    /// At most this many models travel.
    static let modelLimit = 60
}

/// What `nookComposerSet` changes (`CompanionRequest.text`).
enum NookComposerChange: String, Codable, Sendable {
    /// `item` is a model's id from `NookComposerDigest.models`.
    case model
    /// `item` is an access level's id from `accesses`; Nook's widest level is changed on the Mac only.
    case access
    /// Back to every source, as the menu's "Automatic".
    case automatic
    /// `item` a source from `only`, `allow` on or off.
    case only
    /// `item` a source from `never`, `allow` on or off.
    case never
}
