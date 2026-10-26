import Foundation

/// How much model work autocomplete does right now (Settings › Autocomplete › On battery). Plugged in, the model starts on
/// every key and also writes ahead: the next suggestion, the other ways the text could go on, the context of a field you
/// only clicked in. Most of that is never shown. On battery (or in Low Power Mode) Nook only runs the model when you pause
/// and a suggestion can be shown, and can keep it shorter, use a lighter model, or wait until you ask.
struct CompletionPower: Equatable {
    /// Running on the battery, or Low Power Mode is on: the battery settings apply.
    var onBattery = false
    /// No suggestions at all.
    var paused = false
    /// Suggestions only when asked for with the "Suggest now" key (`CompletionPreferences.suggestNow`), or right after one
    /// was taken.
    var onDemand = false
    /// Start the model on the key itself, before the field is read (see `AutocompleteController.speculate`).
    var speculates = true
    /// Write the suggestion after the one on screen while it shows (see `AutocompleteController.writeAhead`).
    var writesAhead = true
    /// Write the other ways the text could go on after each suggestion (see `LlamaCompleter.branch`).
    var branches = true
    /// Read a field's context into the model on a click or a focus change, before the first key (see
    /// `AutocompleteController.warmFocusedField`).
    var warms = true
    /// Wait at least this long after the last key before the model starts, in milliseconds.
    var minimumDelay = 0
    /// At most this many words per suggestion; nil for the usual length.
    var maxWords: Int?
    /// Run a lighter model than the usual one when this Mac has one (see `CompletionModelLocator.lighter`).
    var lighterModel = false

    /// While typing on, a pause this long is when a suggestion is worth writing: shorter pauses fall between two keys.
    static let typingPause = 250
    /// Suggestions on battery have at most this many words when "shorter" is on.
    static let shortWords = 4

    static let full = CompletionPower()

    /// Pure, so it is tested on its own (`CompletionPowerTests`).
    static func plan(prefs: CompletionPreferences, signals: EnergySignals) -> CompletionPower {
        var power = CompletionPower()
        // Low Power Mode is you asking the Mac to save power, also when it is plugged in.
        power.onBattery = signals.onBattery || signals.lowPowerMode
        var fewerRuns = false
        if power.onBattery {
            power.paused = prefs.pauseOnBattery
            power.onDemand = prefs.onDemandOnBattery
            if prefs.shorterOnBattery { power.maxWords = shortWords }
            power.lighterModel = prefs.smallerModelOnBattery
            fewerRuns = prefs.fewerRunsOnBattery
        }
        // A hot Mac gets a break whatever the source of its power: work that is not shown would only keep it hot.
        if signals.hot { fewerRuns = true }
        if fewerRuns {
            power.speculates = false
            power.writesAhead = false
            power.branches = false
            power.warms = false
            power.minimumDelay = typingPause
        }
        // Asked for one at a time: reading a field's context ahead of a request that may never come is wasted.
        if power.onDemand { power.warms = false }
        return power
    }
}
