import XCTest

/// The capability flags per agent, and how a message during a turn reaches the agent.
final class ProviderCapabilityTests: XCTestCase {
    func testFlagsPerProvider() {
        let claude = RunProvider.claude.capabilities
        XCTAssertTrue(claude.canRollbackConversation)
        XCTAssertTrue(claude.canForkFromTurn)
        XCTAssertFalse(RunProvider.codex.capabilities.canForkFromTurn)
        // A model picked during a turn reaches it at once, except where the agent cannot take it mid-turn.
        XCTAssertEqual(RunProvider.allCases.filter { !$0.capabilities.liveSettings }, [.codex, .antigravity])
        for provider in RunProvider.allCases {
            let caps = provider.capabilities
            XCTAssertFalse(caps.pendingRequestsSurviveRestart, "\(provider.rawValue): the process that asked is gone after a restart")
            XCTAssertEqual(caps.turnEndSignal, .strong, provider.rawValue)
            XCTAssertTrue(caps.supportsSteeringByInterruptRestart, provider.rawValue)
            if provider.usesACP {
                XCTAssertFalse(caps.steering, provider.rawValue)
                XCTAssertFalse(caps.canForkFromTurn, provider.rawValue)
            }
        }
    }

    func testNativeSteeringIsNeverReplacedByAnInterrupt() {
        let caps = RunProvider.codex.capabilities
        XCTAssertEqual(SteerRoute.choose(caps, nativeReady: true, active: true, ending: false, waitingOnYou: false), .native)
        XCTAssertEqual(SteerRoute.choose(caps, nativeReady: false, active: true, ending: false, waitingOnYou: false), .unavailable,
                       "Codex still starting its turn: the message waits")
        XCTAssertEqual(SteerRoute.choose(RunProvider.claude.capabilities, nativeReady: true, active: true, ending: false, waitingOnYou: true),
                       .native, "Claude Code takes a message while an approval waits")
    }

    func testAgentsWithoutSteeringAreInterrupted() {
        let caps = RunProvider.gemini.capabilities
        XCTAssertEqual(SteerRoute.choose(caps, nativeReady: false, active: true, ending: false, waitingOnYou: false), .interruptRestart)
        XCTAssertEqual(SteerRoute.choose(caps, nativeReady: false, active: true, ending: false, waitingOnYou: true), .unavailable,
                       "an interrupt would throw away the question or approval that waits for you")
        XCTAssertEqual(SteerRoute.choose(caps, nativeReady: false, active: true, ending: true, waitingOnYou: false), .unavailable,
                       "already being stopped")
        XCTAssertEqual(SteerRoute.choose(caps, nativeReady: false, active: false, ending: false, waitingOnYou: false), .unavailable)
        var off = caps
        off.supportsSteeringByInterruptRestart = false
        XCTAssertEqual(SteerRoute.choose(off, nativeReady: false, active: true, ending: false, waitingOnYou: false), .unavailable)
        var noInterrupt = caps
        noInterrupt.interrupt = false
        XCTAssertEqual(SteerRoute.choose(noInterrupt, nativeReady: false, active: true, ending: false, waitingOnYou: false), .unavailable)
    }

    func testAWaitingApprovalBlocksContinuationUnlessItSurvives() {
        var run = TestData.run(status: .stopped)
        run.statusDetail = "interrupted"
        run.interruptedWhileWaiting = true
        XCTAssertFalse(RestartContinuation.shouldContinue(run, enabled: true, now: run.updatedAt))
    }
}
