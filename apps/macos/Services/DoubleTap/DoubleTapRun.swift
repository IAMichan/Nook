import Foundation

/// One Double Tap from the request to its result: every step Nook took, how it ended, and what it typed, changed or
/// filled in, so the open notch can show all of it while Nook works and after it is done (`DoubleTapRunBar`).
struct DoubleTapRun: Equatable, Identifiable {
    enum StepState: Equatable {
        case running, done, failed
    }

    struct Step: Equatable, Identifiable {
        let id: Int
        var text: String
        var state: StepState
    }

    /// How the run ended; the bar colors its mark by it.
    enum Outcome: Equatable {
        /// Typed, changed or filled in.
        case done
        /// Nothing to do, or handed to the chat.
        case info
        /// The brain or the app would not, or the user is needed (access, a brain).
        case failed
        /// Stop in the notch.
        case stopped
    }

    /// What Nook put in the document, for the user to check: a field and its value, the text it typed, a part it changed.
    struct Check: Equatable, Identifiable {
        let id: Int
        var label: String
        var value: String
    }

    /// Past this many steps the oldest go: a long edit adds one per change.
    static let maxSteps = 30
    /// Past this many checks the rest is counted, not shown.
    static let maxChecks = 12

    let id: UUID
    /// What the user asked in the notch; empty for a plain "fill in".
    var request: String
    let started: Date
    var app = ""
    private(set) var steps: [Step] = []
    /// Nil while Nook works.
    private(set) var outcome: Outcome?
    /// The result in a few words ("Typed in Pages").
    private(set) var result = ""
    private(set) var resultDetail = ""
    private(set) var checks: [Check] = []
    /// Checks left out past `maxChecks`.
    private(set) var moreChecks = 0
    private(set) var ended: Date?
    private var nextID = 0

    init(id: UUID = UUID(), request: String, started: Date = Date()) {
        self.id = id
        self.request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        self.started = started
    }

    var isRunning: Bool { outcome == nil }

    /// The step Nook is on now; the one before it is done. The same line again (a step shown twice) stays one step.
    mutating func step(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !line.isEmpty else { return }
        if let last = steps.last, last.state == .running, last.text == line { return }
        if let index = steps.indices.last, steps[index].state == .running { steps[index].state = .done }
        nextID += 1
        steps.append(Step(id: nextID, text: line, state: .running))
        if steps.count > Self.maxSteps { steps.removeFirst(steps.count - Self.maxSteps) }
    }

    /// What Nook put in the document, to check afterwards. Empty values are left out.
    mutating func check(_ label: String, _ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard checks.count < Self.maxChecks else {
            moreChecks += 1
            return
        }
        nextID += 1
        checks.append(Check(id: nextID, label: label.trimmingCharacters(in: .whitespacesAndNewlines), value: value))
    }

    /// The run is over. The step it was on is done, unless the run failed or was stopped there. Only the first result
    /// counts: a run ends once.
    mutating func finish(_ outcome: Outcome, result: String, detail: String = "", at date: Date = Date()) {
        guard isRunning else { return }
        if let index = steps.indices.last, steps[index].state == .running {
            steps[index].state = (outcome == .failed || outcome == .stopped) ? .failed : .done
        }
        self.outcome = outcome
        self.result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        resultDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        ended = date
    }

    /// How long Nook worked, in whole seconds (at least 1), once it is done.
    var seconds: Int? {
        ended.map { max(1, Int($0.timeIntervalSince(started).rounded())) }
    }
}
