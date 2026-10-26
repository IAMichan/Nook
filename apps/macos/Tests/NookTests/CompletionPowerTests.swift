import XCTest

/// What autocomplete leaves out on battery, in Low Power Mode and on a hot Mac (`CompletionPower`), the "Suggest now" key,
/// and the lighter model it runs on battery.
final class CompletionPowerTests: XCTestCase {
    func testPluggedInEverythingRuns() {
        let power = CompletionPower.plan(prefs: CompletionPreferences(), signals: EnergySignals())
        XCTAssertEqual(power, .full)
        XCTAssertTrue(power.speculates && power.writesAhead && power.branches && power.warms)
        XCTAssertEqual(power.minimumDelay, 0)
        XCTAssertNil(power.maxWords)
    }

    func testOnBatteryTheModelOnlyRunsForWhatShows() {
        let power = CompletionPower.plan(prefs: CompletionPreferences(), signals: EnergySignals(onBattery: true))
        XCTAssertTrue(power.onBattery)
        XCTAssertFalse(power.speculates || power.writesAhead || power.branches || power.warms)
        XCTAssertEqual(power.minimumDelay, CompletionPower.typingPause)
        XCTAssertEqual(power.maxWords, CompletionPower.shortWords)
        XCTAssertFalse(power.paused || power.onDemand || power.lighterModel, "off until turned on")
    }

    func testLowPowerModeCountsAsBatteryEvenPluggedIn() {
        let power = CompletionPower.plan(prefs: CompletionPreferences(), signals: EnergySignals(lowPowerMode: true))
        XCTAssertTrue(power.onBattery)
        XCTAssertFalse(power.speculates)
    }

    func testEachBatterySettingCanBeTurnedOff() {
        var prefs = CompletionPreferences()
        prefs.fewerRunsOnBattery = false
        prefs.shorterOnBattery = false
        let power = CompletionPower.plan(prefs: prefs, signals: EnergySignals(onBattery: true))
        XCTAssertTrue(power.speculates && power.writesAhead && power.branches && power.warms)
        XCTAssertNil(power.maxWords)
    }

    func testOnDemandPauseAndLighterModelOnBattery() {
        var prefs = CompletionPreferences()
        prefs.fewerRunsOnBattery = false
        prefs.onDemandOnBattery = true
        prefs.smallerModelOnBattery = true
        prefs.pauseOnBattery = true
        let power = CompletionPower.plan(prefs: prefs, signals: EnergySignals(onBattery: true))
        XCTAssertTrue(power.onDemand && power.lighterModel && power.paused)
        XCTAssertFalse(power.warms, "no context read ahead of a request that may never come")
        XCTAssertEqual(CompletionPower.plan(prefs: prefs, signals: EnergySignals()), .full, "plugged in, none of it applies")
    }

    func testAHotMacRunsFewerModelsWhateverThePower() {
        var prefs = CompletionPreferences()
        prefs.fewerRunsOnBattery = false
        let power = CompletionPower.plan(prefs: prefs, signals: EnergySignals(hot: true))
        XCTAssertFalse(power.onBattery)
        XCTAssertFalse(power.speculates || power.writesAhead)
        XCTAssertNil(power.maxWords)
    }

    func testSuggestNowKeyIsTakenOnlyWhereAutocompleteWorks() {
        let key = CompletionShortcut(keyCode: 49, modifiers: CompletionShortcut.option, label: "⌥Space")
        var gate = CompletionKeyGate()
        gate.suggestNow = key
        gate.active = true
        let press = CompletionKeyPress(code: 49, modifiers: CompletionShortcut.option, characters: " ")
        XCTAssertTrue(gate.swallows(press))
        gate.showing = .completion
        XCTAssertTrue(gate.swallows(press))
        gate.active = false
        XCTAssertFalse(gate.swallows(press))
    }

    func testLighterModelIsTheLargestClearlySmallerOneOfTheSameKind() {
        func file(_ name: String, _ gigabytes: Double) -> CompletionModelFile {
            CompletionModelFile(url: URL(fileURLWithPath: "/models/\(name)"), bytes: Int64(gigabytes * 1_000_000_000), modified: Date(),
                                info: nil, source: .found)
        }
        let main = file("gemma-4-E4B-it-Q4.gguf", 5)
        let small = file("gemma-4-E2B-it-Q4.gguf", 2.8)
        let tiny = file("qwen3-0.6B-instruct.gguf", 0.5)
        let coder = file("qwen-coder-1.5B-instruct.gguf", 1.5)
        let base = file("gemma-4-E2B-base.gguf", 2.9)
        let almost = file("gemma-4-E4B-it-Q3.gguf", 4)
        let candidates = [main, small, tiny, coder, base, almost]
        XCTAssertEqual(CompletionModelLocator.lighter(than: main, candidates: candidates), small)
        XCTAssertNil(CompletionModelLocator.lighter(than: tiny, candidates: candidates))
    }
}
