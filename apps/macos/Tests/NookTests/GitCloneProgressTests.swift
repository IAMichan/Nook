import XCTest

/// Reading `git clone --progress`: its stages, percentages and detail, the carriage returns it redraws with, and the
/// words a failure is told in.
final class GitCloneProgressTests: XCTestCase {
    func testEachStageIsRead() {
        XCTAssertEqual(GitCloneProgress.parse("remote: Enumerating objects: 1234, done."),
                       GitCloneProgress(stage: .counting, percent: nil, detail: nil))
        XCTAssertEqual(GitCloneProgress.parse("remote: Counting objects:  50% (617/1234)"),
                       GitCloneProgress(stage: .counting, percent: 50, detail: nil))
        XCTAssertEqual(GitCloneProgress.parse("remote: Compressing objects: 100% (800/800), done."),
                       GitCloneProgress(stage: .counting, percent: 100, detail: nil))
        XCTAssertEqual(GitCloneProgress.parse("Receiving objects:  42% (519/1234), 12.40 MiB | 3.10 MiB/s"),
                       GitCloneProgress(stage: .receiving, percent: 42, detail: "12.40 MiB | 3.10 MiB/s"))
        XCTAssertEqual(GitCloneProgress.parse("Receiving objects: 100% (1234/1234), 24.00 MiB | 3.10 MiB/s, done."),
                       GitCloneProgress(stage: .receiving, percent: 100, detail: "24.00 MiB | 3.10 MiB/s"))
        XCTAssertEqual(GitCloneProgress.parse("Resolving deltas:   7% (30/412)"),
                       GitCloneProgress(stage: .resolving, percent: 7, detail: nil))
        XCTAssertEqual(GitCloneProgress.parse("Updating files:  88% (880/1000)"),
                       GitCloneProgress(stage: .checkout, percent: 88, detail: nil))
    }

    func testOtherLinesAreNotProgress() {
        XCTAssertNil(GitCloneProgress.parse("Cloning into 'web'..."))
        XCTAssertNil(GitCloneProgress.parse("fatal: repository 'https://github.com/acme/nope/' not found"))
        XCTAssertNil(GitCloneProgress.parse("warning: You appear to have cloned an empty repository."))
        XCTAssertNil(GitCloneProgress.parse(""))
    }

    func testCarriageReturnsSplitLinesAcrossChunks() {
        var lines = GitCloneProgress.Lines()
        XCTAssertEqual(lines.feed("Cloning into 'web'...\nReceiving objects:   1% (1/100)\rReceiving obj"), ["Cloning into 'web'...", "Receiving objects:   1% (1/100)"])
        XCTAssertEqual(lines.feed("ects:   2% (2/100)\r"), ["Receiving objects:   2% (2/100)"])
        XCTAssertEqual(lines.feed("Resolving deltas: 100% (5/5), done.\r\n"), ["Resolving deltas: 100% (5/5), done."])
        XCTAssertEqual(lines.feed(""), [])
    }

    func testTheWholeCloneGoesFromZeroToOne() {
        let counting = GitCloneProgress(stage: .counting, percent: 0, detail: nil)
        let half = GitCloneProgress(stage: .receiving, percent: 50, detail: nil)
        let done = GitCloneProgress(stage: .checkout, percent: 100, detail: nil)
        XCTAssertEqual(counting.fraction, 0, accuracy: 0.0001)
        XCTAssertEqual(half.fraction, 0.45, accuracy: 0.0001)
        XCTAssertEqual(done.fraction, 1, accuracy: 0.0001)
        XCTAssertLessThan(GitCloneProgress(stage: .receiving, percent: 100, detail: nil).fraction,
                          GitCloneProgress(stage: .resolving, percent: 1, detail: nil).fraction)
    }

    func testAFailureIsToldInGitsWordsWithoutProgressOrPasswords() {
        let stderr = "Cloning into 'web'...\nremote: Enumerating objects: 3, done.\rReceiving objects:  10% (1/3)\r"
            + "fatal: unable to access 'https://ada:s3cret@github.com/acme/web/': Could not resolve host: github.com\n"
        XCTAssertEqual(GitCloneProgress.failure(stderr),
                       "fatal: unable to access 'https://***@github.com/acme/web/': Could not resolve host: github.com")
        XCTAssertNil(GitCloneProgress.failure("Cloning into 'web'...\nReceiving objects: 100% (3/3), done.\n"))
    }

    func testTheNoticeNamesTheRepository() {
        XCTAssertEqual(GitCloneProgress.displayName("https://github.com/acme/web.git"), "acme/web")
        XCTAssertEqual(GitCloneProgress.displayName("git@github.com:acme/web.git"), "acme/web")
        XCTAssertEqual(GitCloneProgress.displayName("ssh://git@gitlab.example.com/group/sub/app/"), "sub/app")
        XCTAssertEqual(GitCloneProgress.displayName("https://example.com/solo"), "solo")
    }

    func testTheSummaryReadsStagePercentAndDetail() {
        let line = GitCloneProgress(stage: .receiving, percent: 42, detail: "12.40 MiB | 3.10 MiB/s").summary
        XCTAssertTrue(line.hasSuffix(" · 42% · 12.40 MiB | 3.10 MiB/s"), line)
        XCTAssertFalse(GitCloneProgress(stage: .counting, percent: nil, detail: nil).summary.contains("·"))
    }

    /// A real clone over git's file transport streams its stderr as it comes, and every chunk adds up to the whole.
    func testAStreamedCloneReportsWhatGitWrites() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("nook-clone-progress-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream").path
        try fm.createDirectory(atPath: upstream, withIntermediateDirectories: true)
        let git = "/usr/bin/git"
        guard fm.isExecutableFile(atPath: git) else { throw XCTSkip("No git") }
        func run(_ arguments: [String], in directory: String) throws {
            let output = try ProcessRunner.run(git, arguments, in: directory)
            XCTAssertEqual(output.status, 0, output.stderr)
        }
        try run(["init", "--quiet"], in: upstream)
        try "hello\n".write(toFile: upstream + "/README", atomically: true, encoding: .utf8)
        try run(["add", "README"], in: upstream)
        try run(["-c", "user.name=Nook", "-c", "user.email=nook@example.com", "commit", "--quiet", "-m", "first"], in: upstream)

        final class Chunks: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func add(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        }
        let chunks = Chunks()
        let target = root.appendingPathComponent("clone").path
        let output = try ProcessRunner.run(git, ["clone", "--progress", "--", "file://" + upstream, target], in: root.path,
                                           timeout: 60, onStderr: { chunks.add($0) }, cancel: ProcessRunner.StopFlag())
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(String(decoding: chunks.data, as: UTF8.self), output.stderr)
        XCTAssertTrue(fm.fileExists(atPath: target + "/README"))
        var lines = GitCloneProgress.Lines()
        let progress = lines.feed(output.stderr + "\n").compactMap(GitCloneProgress.parse)
        XCTAssertTrue(progress.allSatisfy { ($0.percent ?? 0) <= 100 })
    }

    func testACancelStopsTheProgramSoon() throws {
        let stop = ProcessRunner.StopFlag()
        stop.set()
        let started = Date()
        let output = try ProcessRunner.run("/bin/sleep", ["30"], timeout: 60, cancel: stop)
        XCTAssertTrue(output.timedOut, "A cancelled run says it was stopped")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
