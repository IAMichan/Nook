import XCTest

/// One value says which brain is active, and a new install is local without touching anyone's existing choice.
final class BrainSelectionTests: XCTestCase {
    func testLocalIsTheDefaultForANewInstall() {
        XCTAssertTrue(BrainSelection.initialUseLocal(stored: nil, storedProvider: nil, hasAnthropicKey: false))
    }

    func testAnExistingExternalChoiceIsKept() {
        XCTAssertFalse(BrainSelection.initialUseLocal(stored: nil, storedProvider: "openai", hasAnthropicKey: false))
        XCTAssertFalse(BrainSelection.initialUseLocal(stored: nil, storedProvider: nil, hasAnthropicKey: true))
    }

    func testAnExplicitChoiceAlwaysWins() {
        XCTAssertFalse(BrainSelection.initialUseLocal(stored: false, storedProvider: nil, hasAnthropicKey: false))
        XCTAssertTrue(BrainSelection.initialUseLocal(stored: true, storedProvider: "claude", hasAnthropicKey: true))
    }

    func testRuntimeFollowsTheStoredSettings() {
        let mlx = BrainSelection.resolve(useLocal: true, provider: .claude, localModel: "m", providerModel: "x")
        XCTAssertEqual(mlx.runtime, .mlx)
        XCTAssertEqual(mlx.model, "m")
        XCTAssertTrue(mlx.isLocal)
        XCTAssertEqual(BrainSelection.resolve(useLocal: false, provider: .ollama, localModel: "", providerModel: "q").runtime, .ollama)
        XCTAssertEqual(BrainSelection.resolve(useLocal: false, provider: .lmstudio, localModel: "", providerModel: "q").runtime, .lmstudio)
        let cloud = BrainSelection.resolve(useLocal: false, provider: .claude, localModel: "", providerModel: "haiku")
        XCTAssertEqual(cloud.runtime, .external)
        XCTAssertFalse(cloud.isLocal)
    }

    func testStoredValuesRoundTrip() {
        for (useLocal, provider) in [(true, AIProvider.claude), (false, .ollama), (false, .lmstudio), (false, .openai), (false, .claudeCode)] {
            let selection = BrainSelection.resolve(useLocal: useLocal, provider: provider, localModel: "m", providerModel: "p")
            let stored = selection.storedValues
            XCTAssertEqual(stored.useLocal, useLocal)
            XCTAssertEqual(stored.provider, provider)
        }
    }

    func testChoosingTheBuiltInModelNeverLeavesALocalServerProvider() {
        let selection = BrainSelection(runtime: .mlx, provider: .ollama, model: "m")
        XCTAssertEqual(selection.storedValues.useLocal, true)
        XCTAssertFalse(selection.storedValues.provider.isLocalServer)
    }
}
