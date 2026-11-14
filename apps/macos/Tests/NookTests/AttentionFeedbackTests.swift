import XCTest

final class DecayedCounterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecayHalvesEveryHalfLife() {
        XCTAssertEqual(Decay.value(8, elapsed: 0, halfLife: 10), 8)
        XCTAssertEqual(Decay.value(8, elapsed: 10, halfLife: 10), 4, accuracy: 1e-9)
        XCTAssertEqual(Decay.value(8, elapsed: 30, halfLife: 10), 1, accuracy: 1e-9)
        // A clock that runs back fades nothing.
        XCTAssertEqual(Decay.value(8, elapsed: -100, halfLife: 10), 8)
    }

    func testPointsFadeAndAddUp() {
        var counter = DecayedCounter<String>(halfLife: 100)
        counter.add("a", positive: 4, at: start)
        counter.add("a", positive: 1, at: start.addingTimeInterval(100))
        XCTAssertEqual(counter.score("a", at: start.addingTimeInterval(100)), 3, accuracy: 1e-9)
        XCTAssertEqual(counter.score("a", at: start.addingTimeInterval(200)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(counter.score("missing", at: start), 0)
    }

    func testNegativeEvidenceWeighs() {
        var counter = DecayedCounter<String>(halfLife: 100, negativeWeight: 2)
        counter.add("a", positive: 3, negative: 1, at: start)
        XCTAssertEqual(counter.score("a", at: start), 1, accuracy: 1e-9)
        counter.add("b", positive: 2, at: start)
        XCTAssertEqual(counter.ranked(at: start), ["b", "a"])
    }

    func testTheWeakestKeysFallAway() {
        var counter = DecayedCounter<String>(halfLife: 100, limit: 2)
        counter.add("old", positive: 1, at: start)
        counter.add("strong", positive: 5, at: start)
        counter.add("new", positive: 2, at: start.addingTimeInterval(50))
        XCTAssertEqual(Set(counter.entries.keys), ["strong", "new"])
    }

    func testEntriesReadBackWithoutNegativePoints() throws {
        let data = Data(#"{"score":2,"last":0}"#.utf8)
        let entry = try JSONDecoder().decode(DecayedCounter<String>.Entry.self, from: data)
        XCTAssertEqual(entry.score, 2)
        XCTAssertEqual(entry.negative, 0)
    }
}

final class AttentionFeedbackTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnknownIsNeutral() {
        let feedback = AttentionFeedback()
        XCTAssertEqual(feedback.weight(source: "chats", app: "whatsapp", at: now), 0)
        XCTAssertEqual(feedback.gapFactor(source: "chats", app: "whatsapp", at: now), 1)
    }

    func testOftenDismissedWaitsLonger() {
        var feedback = AttentionFeedback()
        for _ in 0..<6 { feedback.record(.dismissed, source: "chats", app: "Slack", subject: "chat:1", at: now) }
        XCTAssertLessThan(feedback.weight(source: "chats", app: "slack", at: now), -0.5)
        let factor = feedback.gapFactor(source: "chats", app: "slack", at: now)
        XCTAssertGreaterThan(factor, 1.5)
        XCTAssertLessThanOrEqual(factor, AttentionFeedback.maxGapFactor)
        // Another app keeps its usual gap.
        XCTAssertEqual(feedback.gapFactor(source: "chats", app: "whatsapp", at: now), 1)
    }

    func testActingOnItNeverMakesItLouder() {
        var feedback = AttentionFeedback()
        for _ in 0..<6 { feedback.record(.opened, source: "agents", app: "codex", at: now) }
        XCTAssertGreaterThan(feedback.weight(source: "agents", app: "codex", at: now), 0.5)
        XCTAssertEqual(feedback.gapFactor(source: "agents", app: "codex", at: now), 1)
    }

    func testTheSubjectAddsToItsApp() {
        var feedback = AttentionFeedback()
        feedback.record(.muted, source: "suggestions", app: "com.apple.mail", subject: "invoice", at: now)
        let app = feedback.weight(source: "suggestions", app: "com.apple.mail", at: now)
        let subject = feedback.weight(source: "suggestions", app: "com.apple.mail", subject: "invoice", at: now)
        XCTAssertLessThan(subject, app)
    }

    func testEvidenceFades() {
        var feedback = AttentionFeedback()
        for _ in 0..<4 { feedback.record(.dismissed, source: "nook", at: now) }
        let fresh = feedback.weight(source: "nook", at: now)
        let later = feedback.weight(source: "nook", at: now.addingTimeInterval(8 * AttentionFeedback.halfLife))
        XCTAssertLessThan(fresh, later)
        XCTAssertEqual(later, 0, accuracy: 0.05)
    }

    func testShownCountsExposureOnly() {
        var feedback = AttentionFeedback()
        feedback.record(.shown, source: "chats", app: "telegram", at: now)
        XCTAssertEqual(feedback.shown(source: "chats", app: "telegram", at: now), 1)
        XCTAssertEqual(feedback.weight(source: "chats", app: "telegram", at: now), 0)
    }

    func testTheStoreKeepsItAcrossLaunches() throws {
        let suite = "AttentionFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AttentionFeedbackStore(defaults: defaults).record(.dismissed, source: "chats", app: "slack", at: now)
        let again = AttentionFeedbackStore(defaults: defaults)
        XCTAssertLessThan(again.feedback.weight(source: "chats", app: "slack", at: now), 0)
    }
}
