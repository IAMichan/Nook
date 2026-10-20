import Foundation

/// How much of its optional background work Nook does (Settings › General › Energy). Work you ask for (a question,
/// dictation, a look at the screen) always runs at full speed; this is about what Nook does by himself: reading the
/// screen on a timer, thinking along, looking for agents, checking for meetings.
enum EnergyMode: String, CaseIterable, Identifiable, Codable {
    /// Nook steps back on battery, when the Mac is hot or busy, and when you are away.
    case automatic
    /// Always light: the screen is read less often and suggestions come less often, wherever the power comes from.
    case saver
    /// Never slows down for battery or a busy Mac; a hot Mac still gets a break.
    case full

    var id: String { rawValue }

    var titleKey: String { "settings.energy.mode.\(rawValue)" }
    var detailKey: String { "settings.energy.mode.\(rawValue).detail" }
}

/// What the Mac tells Nook right now, as `EnergyPolicy` reads it. Gathered by `EnergyMonitor`; a test fills it in by hand.
struct EnergySignals: Equatable {
    /// macOS Low Power Mode is on.
    var lowPowerMode = false
    /// The thermal state is serious or critical.
    var hot = false
    /// Every core has more than enough to do (a build, an export).
    var busy = false
    /// Running on the battery.
    var onBattery = false
    /// No keyboard or pointer input for a while.
    var away = false
    /// The displays are asleep.
    var displayAsleep = false

    /// After this long without input you count as away: nothing on screen is being looked at.
    static let awayAfter: TimeInterval = 300
}

/// Why Nook does less than usual right now, in the order the status line names them.
enum EnergyReason: String, CaseIterable, Equatable {
    case displayAsleep, hot, lowPowerMode, busy, away, battery, saver

    var textKey: String { "settings.energy.reason.\(rawValue)" }
}

/// The tempo of the background work.
enum EnergyPace: Equatable {
    /// Everything as usual.
    case full
    /// The same work, less often.
    case light
    /// Optional work waits; what remains runs slowly.
    case paused
}

/// What the background work should do right now: the pace, why, and the knobs the workers read.
struct EnergyPlan: Equatable {
    var pace: EnergyPace
    var reasons: [EnergyReason]

    /// Multiply a worker's usual interval by this: 1 at full speed, 2 when light, 6 when paused.
    var slowdown: Double {
        switch pace {
        case .full: return 1
        case .light: return 2
        case .paused: return 6
        }
    }

    /// The screen is read on a timer, so an answer about it is ready at once.
    var readsScreen: Bool { pace != .paused }

    /// Nook looks over your shoulder and offers help by himself.
    var thinksAlong: Bool { pace != .paused }

    /// At least this long between two looks while thinking along, on top of the usual gaps: a look is a model run.
    var thinkAlongGap: TimeInterval {
        switch pace {
        case .full: return 0
        case .light: return 600
        case .paused: return .infinity
        }
    }

    // MARK: GPU and CPU

    /// How many windows the screen reader's timer runs through Vision at once. Each recognition is a burst on the GPU and
    /// the Neural Engine; ten at a time is a spike you notice as a stutter and as heat, one after the other is not.
    var ocrConcurrency: Int { pace == .full ? 3 : 1 }

    /// How many windows the timer keeps text of. Taking it easy, only the frontmost few: the others are captured and read
    /// again fresh the moment a question asks about them.
    var screenWindowLimit: Int { pace == .full ? 10 : 4 }

    /// How old a window that is not in front may get before the timer captures it again.
    var backgroundWindowMaxAge: TimeInterval { pace == .full ? 30 : 90 }

    /// The longest side, in pixels, of a capture of a window that is not in front: it is read with fast recognition anyway,
    /// and a smaller picture is a smaller readback from the GPU and a shorter recognition.
    var backgroundCaptureMaxSide: Int { pace == .full ? 2400 : 1600 }

    /// Frames per second of the live picture of a Mac app next to the chat: as smooth as the screen at full speed, half
    /// of that on battery, where every frame is a GPU copy and a composite.
    var mirrorFrameRate: Int { pace == .full ? 60 : 30 }

    /// Frames per second of Nook in the closed notch while he thinks along without the pointer on him.
    var idleOrbFrameRate: Double { pace == .full ? 12 : 8 }

    /// The first reason, for a short status line; nil at full speed.
    var mainReason: EnergyReason? { reasons.first }

    static let fullSpeed = EnergyPlan(pace: .full, reasons: [])
}

/// Decides the plan from the signals and your choice. Pure, so it is tested on its own (`EnergyPolicyTests`).
enum EnergyPolicy {
    static func plan(for signals: EnergySignals, mode: EnergyMode) -> EnergyPlan {
        var paused: [EnergyReason] = []
        var light: [EnergyReason] = []

        // Nobody is looking at the screen: the optional work has nothing to add.
        if signals.displayAsleep { paused.append(.displayAsleep) }
        // A hot Mac gets a break whatever you chose; working on would only keep it hot.
        if signals.hot { paused.append(.hot) }
        // Low Power Mode is you asking macOS to save power: Nook follows, unless you told him to keep going.
        if signals.lowPowerMode {
            if mode == .full { light.append(.lowPowerMode) } else { paused.append(.lowPowerMode) }
        }
        // Every core is full: Nook never competes with what you are doing, unless you told him not to mind.
        if signals.busy, mode != .full { paused.append(.busy) }
        if signals.away { paused.append(.away) }
        if signals.onBattery, mode != .full { light.append(.battery) }
        if mode == .saver { light.append(.saver) }

        if !paused.isEmpty { return EnergyPlan(pace: .paused, reasons: paused + light) }
        if !light.isEmpty { return EnergyPlan(pace: .light, reasons: light) }
        return .fullSpeed
    }
}
