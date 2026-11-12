import XCTest

/// The shared helper that runs short programs: it never hangs past its deadline and never crashes on a closed pipe.
final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutStderrAndStatus() throws {
        let result = try ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stdoutData, Data("out\n".utf8))
        XCTAssertEqual(result.stderr, "err\n")
        XCTAssertFalse(result.timedOut)
    }

    func testStdinReachesTheProgram() throws {
        let result = try ProcessRunner.run("/bin/cat", [], stdin: Data("hello\n".utf8), timeout: 10)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.status, 0)
    }

    /// More than a pipe holds goes in while the output comes out, so neither side waits on the other.
    func testLargeStdinRoundTrips() throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 1_000_000)
        let result = try ProcessRunner.run("/bin/cat", [], stdin: payload, timeout: 30)
        XCTAssertEqual(result.stdoutData.count, payload.count)
        XCTAssertFalse(result.timedOut)
    }

    /// A program that exits without reading its input: the legacy write raised an exception here and crashed Nook.
    func testStdinToAProgramThatExitsImmediatelyDoesNotCrash() throws {
        let payload = Data(repeating: 0x41, count: 1_000_000)
        let started = Date()
        let result = try ProcessRunner.run("/usr/bin/true", [], stdin: payload, timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTimeoutEndsAHangingProgram() throws {
        let started = Date()
        let result = try ProcessRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A grandchild that keeps stdout open after the program itself has gone cannot hold the caller past the deadline.
    func testTimeoutIsNotHeldByAGrandchildKeepingStdoutOpen() throws {
        let started = Date()
        let result = try ProcessRunner.run("/bin/sh", ["-c", "echo started; /bin/sleep 30 & exit 0"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.stdout, "started\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A program that does not read its input and does not exit: the deadline still ends it.
    func testTimeoutWithUnreadStdin() throws {
        let started = Date()
        let payload = Data(repeating: 0x41, count: 1_000_000)
        let result = try ProcessRunner.run("/bin/sleep", ["30"], stdin: payload, timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testFeedToAClosedPipeDoesNotCrash() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        ProcessRunner.feed(Data(repeating: 0x41, count: 200_000), to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        // The writer runs in the background; give it time to hit the closed pipe.
        Thread.sleep(forTimeInterval: 0.3)
    }

    func testMissingExecutableThrows() {
        XCTAssertThrowsError(try ProcessRunner.run("/nonexistent/program-\(UUID().uuidString)", [], timeout: 5))
    }
}
