import XCTest

/// The button next to a chat error offers what actually fixes it.
final class ChatRecoveryTests: XCTestCase {
    private func selection(_ runtime: BrainRuntime) -> BrainSelection {
        switch runtime {
        case .mlx: return .resolve(useLocal: true, provider: .claude, localModel: "m", providerModel: "")
        case .ollama: return .resolve(useLocal: false, provider: .ollama, localModel: "", providerModel: "q")
        case .lmstudio: return .resolve(useLocal: false, provider: .lmstudio, localModel: "", providerModel: "q")
        case .external: return .resolve(useLocal: false, provider: .claude, localModel: "", providerModel: "haiku")
        }
    }

    func testTheBuiltInModelAlwaysPointsToTheModelChoice() {
        XCTAssertEqual(ChatRecoveryAction.forError("Out of memory", selection: selection(.mlx)), .chooseModel)
    }

    func testALocalServerThatDoesNotAnswerIsOpened() {
        XCTAssertEqual(ChatRecoveryAction.forError("Could not connect to the server.", selection: selection(.ollama)), .openLocalServer(.ollama))
        XCTAssertEqual(ChatRecoveryAction.forError("The network connection was lost.", selection: selection(.lmstudio)), .openLocalServer(.lmstudio))
        XCTAssertEqual(ChatRecoveryAction.forError("model not found", selection: selection(.ollama)), .chooseModel)
    }

    func testRejectedCredentialsOfTheBrainPointToReconnecting() {
        XCTAssertEqual(ChatRecoveryAction.forError("No API key configured. Add one in Settings › Brain.", selection: selection(.external)), .reconnectBrain)
        XCTAssertEqual(ChatRecoveryAction.forError("The service rejected the API key (401).", selection: selection(.external)), .reconnectBrain)
    }

    func testRejectedCredentialsOfAConnectionPointToTheConnection() {
        let text = "The credentials were rejected (401). Check them in Settings › Integrations."
        XCTAssertEqual(ChatRecoveryAction.forError(text, selection: selection(.external)), .reconnectConnection)
    }

    func testAnythingElseOpensSettings() {
        XCTAssertEqual(ChatRecoveryAction.forError("Something odd happened.", selection: selection(.external)), .openSettings)
    }
}
