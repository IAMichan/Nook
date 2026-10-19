import XCTest

final class CommandConsoleTests: XCTestCase {
    private func bash(_ command: String, state: RunEvent.State, output: String? = nil) -> RunEvent {
        RunEvent(kind: .tool, text: "Bash · " + command, tool: "Bash", callID: UUID().uuidString,
                 detail: #"{"command":"\#(command)"}"#, output: output, state: state)
    }

    func testRunningFindsTheCommandOfTheLatestTurn() {
        let old = bash("ls", state: .running)
        let read = RunEvent(kind: .tool, text: "Read · a.swift", tool: "Read", state: .running)
        let test = bash("npm test", state: .running)
        let events = [RunEvent(kind: .user, text: "hi"), old, RunEvent(kind: .user, text: "again"), read, test]
        XCTAssertEqual(CommandConsole.running(events)?.id, test.id)
        XCTAssertNil(CommandConsole.running([RunEvent(kind: .user, text: "hi"), read]))
        XCTAssertNil(CommandConsole.running([RunEvent(kind: .user, text: "hi"), bash("ls", state: .done)]))
    }

    func testCommandLineComesFromTheInput() {
        XCTAssertEqual(CommandConsole.commandLine(bash("npm test", state: .running)), "npm test")
    }

    func testOutputDropsEscapesAndRedrawnLines() {
        XCTAssertEqual(CommandConsole.output("\u{1B}[32mok\u{1B}[0m\r\nnext"), "ok\nnext")
        XCTAssertEqual(CommandConsole.output("10%\r50%\r100%\ndone"), "100%\ndone")
        XCTAssertEqual(CommandConsole.output(nil), "")
    }
}
