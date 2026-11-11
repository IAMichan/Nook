import XCTest

/// How much room the coding agents may take (`AgentGovernorPolicy`): background when the Mac is pressed, the youngest
/// agents' commands wait when it swaps, and everything comes back by itself.
final class AgentGovernorPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func agents(_ count: Int, work: Bool = true) -> [AgentLoad] {
        (0..<count).map { AgentLoad(pid: Int32(100 + $0), started: t0.addingTimeInterval(Double($0) * 60), hasWork: work) }
    }

    private func throttles(_ states: [Int32: AgentGovernorState]) -> [Int32: AgentThrottle] {
        states.mapValues(\.throttle)
    }

    func testStrainReadsMemoryAndHeatButNotABusyProcessor() {
        XCTAssertEqual(AgentGovernorPolicy.strain(pressureLevel: 1, swapinsPerSecond: 0, hot: false), .calm)
        XCTAssertEqual(AgentGovernorPolicy.strain(pressureLevel: 1, swapinsPerSecond: nil, hot: true), .pressed)
        XCTAssertEqual(AgentGovernorPolicy.strain(pressureLevel: 2, swapinsPerSecond: nil, hot: false), .pressed)
        XCTAssertEqual(AgentGovernorPolicy.strain(pressureLevel: 1, swapinsPerSecond: EnergySignals.swapinsPerSecondTight, hot: false), .pressed)
        // macOS can say "normal" while the Mac swaps hard: the rate alone makes it critical.
        XCTAssertEqual(AgentGovernorPolicy.strain(pressureLevel: 1, swapinsPerSecond: AgentGovernorPolicy.swapinsPerSecondCritical, hot: false), .critical)
        XCTAssertEqual(AgentGovernorPolicy.strain(pressureLevel: 4, swapinsPerSecond: 0, hot: false), .critical)
    }

    func testCalmMacLeavesAgentsAlone() {
        let next = AgentGovernorPolicy.next(agents: agents(3), current: [:], strain: .calm, calmSince: t0, now: t0)
        XCTAssertEqual(Set(throttles(next).values), [.normal])
    }

    func testPressedMacMovesEveryAgentToTheBackground() {
        let next = AgentGovernorPolicy.next(agents: agents(3), current: [:], strain: .pressed, calmSince: t0, now: t0)
        XCTAssertEqual(Set(throttles(next).values), [.background])
        let back = AgentGovernorPolicy.next(agents: agents(3), current: next, strain: .calm, calmSince: t0, now: t0 + 10)
        XCTAssertEqual(Set(throttles(back).values), [.normal])
    }

    func testCriticalPausesTheYoungestOneAtATimeAndTheOldestGoesOn() {
        let all = agents(3)
        let now = t0 + 600
        let first = AgentGovernorPolicy.next(agents: all, current: [:], strain: .critical, calmSince: nil, now: now)
        XCTAssertEqual(throttles(first), [100: .background, 101: .background, 102: .paused], "the youngest waits first")
        let second = AgentGovernorPolicy.next(agents: all, current: first, strain: .critical, calmSince: nil, now: now + 5)
        XCTAssertEqual(throttles(second), [100: .background, 101: .paused, 102: .paused])
        let third = AgentGovernorPolicy.next(agents: all, current: second, strain: .critical, calmSince: nil, now: now + 10)
        XCTAssertEqual(third[100]?.throttle, .background, "one agent always keeps going")
    }

    func testOneAgentAloneIsNeverPaused() {
        let next = AgentGovernorPolicy.next(agents: agents(1), current: [:], strain: .critical, calmSince: nil, now: t0)
        XCTAssertEqual(throttles(next), [100: .background])
        // Agents without commands of their own have nothing to pause.
        let idle = AgentGovernorPolicy.next(agents: agents(3, work: false), current: [:], strain: .critical, calmSince: nil, now: t0)
        XCTAssertFalse(idle.values.contains { $0.throttle == .paused })
    }

    func testPausedWorkComesBackOneAtATimeOnceTheMacHasRoom() {
        let all = agents(3)
        let now = t0 + 600
        let paused: [Int32: AgentGovernorState] = [
            100: AgentGovernorState(throttle: .background, since: now),
            101: AgentGovernorState(throttle: .paused, since: now),
            102: AgentGovernorState(throttle: .paused, since: now)
        ]
        // Out of the critical state, but not long enough yet.
        let early = AgentGovernorPolicy.next(agents: all, current: paused, strain: .pressed, calmSince: now + 20, now: now + 25)
        XCTAssertEqual(early[101]?.throttle, .paused)
        let later = AgentGovernorPolicy.next(agents: all, current: early, strain: .pressed,
                                             calmSince: now + 20, now: now + 20 + AgentGovernorPolicy.resumeAfterCalm)
        XCTAssertEqual(throttles(later), [100: .background, 101: .background, 102: .paused], "the oldest paused one first")
        let after = AgentGovernorPolicy.next(agents: all, current: later, strain: .calm,
                                             calmSince: now + 20, now: now + 25 + AgentGovernorPolicy.resumeAfterCalm)
        XCTAssertEqual(Set(throttles(after).values), [.normal])
    }

    func testAPauseEndsAfterTheLimitAndIsNotRepeatedRightAway() {
        let all = agents(2)
        let now = t0 + 600
        let paused: [Int32: AgentGovernorState] = [101: AgentGovernorState(throttle: .paused, since: now)]
        let end = now + AgentGovernorPolicy.maxPause
        let next = AgentGovernorPolicy.next(agents: all, current: paused, strain: .critical, calmSince: nil, now: end)
        XCTAssertEqual(next[101]?.throttle, .background, "still critical, but the pause took long enough")
        let again = AgentGovernorPolicy.next(agents: all, current: next, strain: .critical, calmSince: nil, now: end + 5)
        XCTAssertEqual(again[101]?.throttle, .background, "not paused again during the cooldown")
        let later = AgentGovernorPolicy.next(agents: all, current: again, strain: .critical, calmSince: nil,
                                             now: end + AgentGovernorPolicy.pauseCooldown)
        XCTAssertEqual(later[101]?.throttle, .paused)
    }

    func testAnAgentYouLetGoOnIsNeverPaused() {
        var all = agents(3)
        all[2].exempt = true
        let next = AgentGovernorPolicy.next(agents: all, current: [:], strain: .critical, calmSince: nil, now: t0 + 600)
        XCTAssertEqual(throttles(next), [100: .background, 101: .paused, 102: .background])
        // Let go on while paused: it comes back at once.
        all[1].exempt = true
        let freed = AgentGovernorPolicy.next(agents: all, current: next, strain: .critical, calmSince: nil, now: t0 + 605)
        XCTAssertEqual(freed[101]?.throttle, .background)
    }
}

final class AgentWorkTreeTests: XCTestCase {
    func testFindsTheCommandsAnAgentRunsInGroupsOfTheirOwn() {
        // Nook 1 → agent 10 (group 10) → helper 11 (group 10); shell 20 (group 20) → xcodebuild 21 → compiler 22 (group 20);
        // shell 30 (group 30). An unrelated 40 (group 40) under Nook.
        let table = [
            ProcessEntry(pid: 10, parent: 1, group: 10), ProcessEntry(pid: 11, parent: 10, group: 10),
            ProcessEntry(pid: 20, parent: 10, group: 20), ProcessEntry(pid: 21, parent: 20, group: 20),
            ProcessEntry(pid: 22, parent: 21, group: 20), ProcessEntry(pid: 30, parent: 10, group: 30),
            ProcessEntry(pid: 40, parent: 1, group: 40)
        ]
        let work = AgentWork.of(agent: 10, in: table)
        XCTAssertEqual(work.groups, [20, 30], "never the agent's own group")
        XCTAssertEqual(work.processes, [20, 21, 22, 30])
        XCTAssertEqual(AgentWork.of(agent: 40, in: table), AgentWork(processes: [], groups: []))
    }
}
