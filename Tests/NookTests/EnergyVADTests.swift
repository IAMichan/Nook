import XCTest

/// The wake word's voice detection: quiet stays quiet, speech starts a segment, silence ends it.
final class EnergyVADTests: XCTestCase {
    func testSpeechStartsAndSilenceEnds() {
        var vad = EnergyVAD()
        vad.setFrameRate(10)   // 100 ms buffers, as macOS often delivers
        for _ in 0..<10 { XCTAssertEqual(vad.feed(1e-6), EnergyVAD.Event.none, "calibrating on silence") }
        XCTAssertEqual(vad.feed(1e-6), EnergyVAD.Event.none)
        XCTAssertEqual(vad.feed(1e-3), .start, "a voice far above the noise floor")
        for _ in 0..<5 { _ = vad.feed(1e-3) }
        var ended = false
        for _ in 0..<12 { if vad.feed(1e-6) == .end { ended = true; break } }
        XCTAssertTrue(ended, "about 0.8 s of silence ends the segment")
        XCTAssertFalse(vad.isActive)
    }

    func testANoisyRoomIsNotSpeech() {
        var vad = EnergyVAD()
        vad.setFrameRate(10)
        for _ in 0..<200 { XCTAssertNotEqual(vad.feed(2e-4 * Double.random(in: 0.8...1.2)), .start) }
    }
}
