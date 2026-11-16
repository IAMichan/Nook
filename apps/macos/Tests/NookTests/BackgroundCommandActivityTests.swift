import XCTest

final class BackgroundCommandActivityTests: XCTestCase {
    private func sample(_ pid: Int32, _ parent: Int32, cpu: UInt64 = 0, started: UInt64 = 1, name: String = "") -> ProcessSample {
        ProcessSample(pid: pid, parent: parent, started: started, cpuNanoseconds: cpu, memoryBytes: 0, name: name)
    }

    func testFindsTheCommandAsTheShellThatEvalsItQuoted() {
        let command = "./scripts/core-tests.sh --changed 2>&1 | grep -E 'failed|error'"
        let lines: [Int32: String] = [
            // The agent, an MCP server it runs, the shell of the command and what that started.
            10: "claude -p", 11: "node mcp-server.js",
            12: "/bin/zsh -c source snap.sh && eval './scripts/core-tests.sh --changed 2>&1 | grep -E '\\''failed|error'\\''' < /dev/null",
            13: "/bin/bash ./scripts/core-tests.sh --changed", 14: "swift build",
        ]
        let table = [sample(10, 1), sample(11, 10), sample(12, 10), sample(13, 12), sample(14, 13), sample(20, 1)]
        let found = BackgroundCommandActivity.processes(of: command, roots: [10], in: table) { lines[$0] }
        XCTAssertEqual(Set(found.map(\.pid)), [12, 13, 14], "the shell and everything below it, not the MCP server")
    }

    func testFindsACommandHeldAsItIs() {
        let table = [sample(10, 1), sample(12, 10)]
        let found = BackgroundCommandActivity.processes(of: "npm run dev", roots: [10], in: table) { $0 == 12 ? "bash -lc npm run dev" : nil }
        XCTAssertEqual(found.map(\.pid), [12])
        XCTAssertTrue(BackgroundCommandActivity.processes(of: "npm run dev", roots: [], in: table) { _ in "npm run dev" }.isEmpty)
    }

    func testReadsWorkingWaitingAndGone() {
        let command = "make all"
        var probe = BackgroundCommandProbe()
        let line: (Int32) -> String? = { $0 == 12 ? "sh -c make all" : nil }
        func table(cpu: UInt64) -> [ProcessSample] {
            [sample(10, 1), sample(12, 10, cpu: 0, started: 1, name: "sh"), sample(13, 12, cpu: cpu, started: 2, name: "clang")]
        }
        let first = probe.read(command: command, output: nil, roots: [10], table: table(cpu: 0), at: 0, commandLine: line) { _ in nil }
        XCTAssertEqual(first?.state, .working, "no CPU figure yet: it runs")
        XCTAssertNil(first?.cpuPercent)
        let busy = probe.read(command: command, output: nil, roots: [10], table: table(cpu: 2_000_000_000), at: 2, commandLine: line) { _ in nil }
        XCTAssertEqual(busy?.state, .working)
        XCTAssertEqual(busy?.cpuPercent ?? 0, 100, accuracy: 0.1)
        XCTAssertEqual(busy?.process, "clang")
        let idle = probe.read(command: command, output: nil, roots: [10], table: table(cpu: 2_000_000_000), at: 4, commandLine: line) { _ in nil }
        XCTAssertEqual(idle?.state, .waiting)
        XCTAssertEqual(idle?.process, "clang", "the newest process when none uses CPU")
        let gone = [sample(10, 1)]
        XCTAssertNil(probe.read(command: command, output: nil, roots: [10], table: gone, at: 6, commandLine: line) { _ in nil },
                     "one miss may be a process between two steps")
        XCTAssertEqual(probe.read(command: command, output: nil, roots: [10], table: gone, at: 8, commandLine: line) { _ in nil }?.state, .gone)
    }

    func testReadsTheOutputFileFromClaudeCodesNote() {
        let note = "Command did not complete within its 600s timeout and was moved to the background (ID: b2z8). Output is being written to: /private/tmp/claude-501/x/tasks/b2z8.output. You will be notified when it completes."
        XCTAssertEqual(BackgroundCommandActivity.outputFile(note), "/private/tmp/claude-501/x/tasks/b2z8.output")
        XCTAssertNil(BackgroundCommandActivity.outputFile("built"))
        var probe = BackgroundCommandProbe()
        let date = Date(timeIntervalSince1970: 100)
        let read = probe.read(command: "make", output: note, roots: [10], table: [sample(10, 1), sample(12, 10)], at: 0,
                              commandLine: { $0 == 12 ? "make" : nil }) { $0.hasSuffix("b2z8.output") ? date : nil }
        XCTAssertEqual(read?.lastOutput, date)
        XCTAssertEqual(read?.hasOutputFile, true)
    }

    func testFindsACommandQuotedTheNewerWay() {
        let line = #"/bin/zsh -c source snap.sh && eval 'python3 - <<'"'"'EOF'"'"'"# + "\np='x'\nEOF' < /dev/null"
        XCTAssertTrue(BackgroundCommandActivity.runs(line, "python3 - <<'EOF'\np='x'\nEOF"))
        XCTAssertFalse(BackgroundCommandActivity.runs(line, "python3 - <<'END'"))
    }

    func testCountsAsEndedOnlyAfterStayingGoneWithStillOutput() {
        let command = "make all"
        var probe = BackgroundCommandProbe()
        let line: (Int32) -> String? = { $0 == 12 ? "sh -c make all" : nil }
        let note = "Output is being written to: /tmp/x/tasks/b1.output."
        var written = Date(timeIntervalSince1970: 100)
        let alive = [sample(10, 1), sample(12, 10)], gone = [sample(10, 1)]
        _ = probe.read(command: command, output: note, roots: [10], table: alive, at: 0, commandLine: line) { _ in written }
        XCTAssertFalse(probe.ended(at: 100), "it runs")
        _ = probe.read(command: command, output: note, roots: [10], table: gone, at: 3, commandLine: line) { _ in written }
        _ = probe.read(command: command, output: note, roots: [10], table: gone, at: 6, commandLine: line) { _ in written }
        XCTAssertFalse(probe.ended(at: 6), "gone only a moment")
        written = Date(timeIntervalSince1970: 200)
        _ = probe.read(command: command, output: note, roots: [10], table: gone, at: 40, commandLine: line) { _ in written }
        XCTAssertFalse(probe.ended(at: 60), "its output changed at 40: something still writes it")
        _ = probe.read(command: command, output: note, roots: [10], table: gone, at: 90, commandLine: line) { _ in written }
        XCTAssertTrue(probe.ended(at: 90), "gone and still for longer than endedAfter")
        _ = probe.read(command: command, output: note, roots: [10], table: alive, at: 93, commandLine: line) { _ in written }
        XCTAssertFalse(probe.ended(at: 200), "its process is back")
    }
}
