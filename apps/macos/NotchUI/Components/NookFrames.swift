import SwiftUI

/// One clock for every animation that runs on its own for long stretches: Nook, his ring, the equalizer, the working
/// dots and spinners, the shimmer on a running step.
///
/// Each `TimelineView(.animation(minimumInterval:))` keeps its own time. Five of them at 12, 30 and 60 frames a second
/// land on different display frames, so together they asked for a frame almost every time the display had one, and
/// every frame lays out and commits the whole window they are in (four notches, the main window with a long chat).
/// On this clock every frame falls on a shared grid of 1/120 s counted from a fixed moment, a whole number of steps
/// apart: frames of different animations that coincide carry the same date and cost one update of the window. Rates
/// that divide each other (60, 30, 15, 7.5) fall entirely on each other's frames.
struct NookFrames: TimelineSchedule {
    /// Steps of the shared grid in one second.
    private static let grid = 120.0

    /// Grid steps between two frames.
    private let step: Int
    private let paused: Bool

    /// Frames at about `fps` a second, on the shared grid; one frame only (the content as it is now) while `paused`.
    init(fps: Double, paused: Bool = false) {
        step = max(1, Int((Self.grid / max(1, fps)).rounded()))
        self.paused = paused
    }

    struct Entries: Sequence, IteratorProtocol {
        fileprivate var tick: Int
        fileprivate let step: Int
        fileprivate var single: Date?
        fileprivate let paused: Bool

        mutating func next() -> Date? {
            if paused {
                defer { single = nil }
                return single
            }
            defer { tick += step }
            return Date(timeIntervalSinceReferenceDate: Double(tick) / NookFrames.grid)
        }
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        // The frame at or just before `startDate`, so the content shows at once; then every `step` on the grid.
        let now = Int((startDate.timeIntervalSinceReferenceDate * Self.grid).rounded(.down))
        return Entries(tick: now - now % step, step: step, single: startDate, paused: paused)
    }
}

extension TimelineSchedule where Self == NookFrames {
    /// Nook's shared animation clock (`NookFrames`) at about `fps` frames a second.
    static func nookFrames(fps: Double, paused: Bool = false) -> NookFrames {
        NookFrames(fps: fps, paused: paused)
    }
}
