import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs an executable with an argument list (never via a shell) and returns its stdout and stderr.
///
/// The one place that starts a short-lived helper program and waits for it. It is safe in the ways hand-written
/// `Process` + `Pipe` code tends not to be:
/// - stdout and stderr are drained at the same time, so a program with a lot of output on either never deadlocks;
/// - input goes in from a background queue while the output is read (`feed`), so a payload larger than the pipe buffer
///   cannot block before the deadline is armed, and a program that exits without reading it cannot crash Nook (the
///   legacy `FileHandle.write(_:)` raises an Objective-C exception on a closed pipe, which no Swift code can catch);
/// - the deadline also stops the readers, so a grandchild that keeps stdout open cannot hang the caller.
enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut = false
        /// The raw bytes of stdout, for callers that decode JSON or binary output.
        var stdoutData = Data()
    }

    /// How long a program gets after `terminate()` before it is killed.
    static let killGrace: TimeInterval = 3

    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                    environment: [String: String]? = nil, stdin: Data? = nil, timeout: TimeInterval = 60) throws -> Output {
        // Foundation autoreleases the pipes and their file handles. A caller that runs many commands in one long loop
        // (the Worktrees list runs several per worktree) never reaches a drained pool, so without this pool every pipe
        // stays open until the loop ends; on 2026-11-10 that piled up 4700 pipes and Nook ran out of file descriptors.
        try autoreleasepool {
            try runInPool(executable, arguments, in: directory, environment: environment, stdin: stdin, timeout: timeout)
        }
    }

    /// Body of `run`, called inside its autorelease pool: starts the process, feeds stdin, drains stdout and stderr, waits.
    private static func runInPool(_ executable: String, _ arguments: [String], in directory: String?,
                                  environment: [String: String]?, stdin: Data?, timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        let input = stdin == nil ? nil : Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input ?? FileHandle.nullDevice

        defer {
            try? out.fileHandleForReading.close()
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForReading.close()
            try? err.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
            try? input?.fileHandleForWriting.close()
        }

        try process.run()
        // Our copies of the child's ends: without closing them the readers never see the end of the output, and the
        // writer never notices that the child stopped reading.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        try? input?.fileHandleForReading.close()

        let stop = StopFlag()
        let deadline = Date().addingTimeInterval(timeout)
        if let input, let stdin {
            feed(stdin, to: input.fileHandleForWriting, until: deadline, stop: stop)
            // The writer has its own descriptor; closing ours lets the child see the end of its input once it is written.
            try? input.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently, otherwise a process with heavy output deadlocks.
        let outData = DataBox()
        let errData = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outData), (err, errData)] {
            group.enter()
            let fd = pipe.fileHandleForReading.fileDescriptor
            DispatchQueue.global(qos: .userInitiated).async {
                box.data = drain(fd, stop: stop)
                group.leave()
            }
        }
        var timedOut = false
        if group.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            timedOut = true
            terminate(process)
            // Whatever still holds the pipes open (a grandchild, a program ignoring SIGTERM) no longer keeps us waiting.
            stop.set()
            group.wait()
        }
        if process.isRunning, !wait(for: process, seconds: timedOut ? 0 : max(1, deadline.timeIntervalSinceNow)) {
            timedOut = true
            terminate(process)
        }
        process.waitUntilExit()
        stop.set()
        return Output(status: process.terminationStatus,
                      stdout: String(decoding: outData.data, as: UTF8.self),
                      stderr: String(decoding: errData.data, as: UTF8.self),
                      timedOut: timedOut,
                      stdoutData: outData.data)
    }

    // MARK: Input

    /// Writes `data` to a child's stdin from a background queue, so reading its output can go on at the same time.
    ///
    /// It writes to a duplicate of `handle`'s descriptor and closes that duplicate when it is done, when the child stops
    /// reading, at `deadline`, or when `stop` is set. The caller owns `handle` and closes it as usual; closing it right
    /// after this call is fine and makes the child see the end of its input once everything is written. A child that
    /// exits without reading never crashes Nook: the write fails with EPIPE instead of raising or sending SIGPIPE.
    static func feed(_ data: Data, to handle: FileHandle, until deadline: Date? = nil, stop: StopFlag? = nil) {
        let fd = dup(handle.fileDescriptor)
        guard fd >= 0 else { return }
        configureForWriting(fd)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(fd) }
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    if stop?.isSet == true { return }
                    if let deadline, Date() >= deadline { return }
                    let written = write(fd, pointer, remaining)
                    if written > 0 {
                        pointer += written
                        remaining -= written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&poller, 1, 200)
                    } else {
                        // EPIPE (the child closed its input or exited) or another error: stop quietly.
                        return
                    }
                }
            }
        }
    }

    /// Non-blocking, so the writer can notice the deadline, and no SIGPIPE when the reader has gone.
    private static func configureForWriting(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        #if canImport(Darwin)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        #else
        _ = ignoreSIGPIPE
        #endif
    }

    #if !canImport(Darwin)
    private static let ignoreSIGPIPE: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    #endif

    // MARK: Output

    /// Reads `fd` to its end, or until `stop` is set. Polls, so a pipe that a grandchild keeps open cannot block forever.
    private static func drain(_ fd: Int32, stop: StopFlag) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !stop.isSet {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                return data
            }
            if ready == 0 { continue }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return data
            }
        }
        return data
    }

    // MARK: Ending

    /// SIGTERM, then SIGKILL when the program has not gone after `killGrace`.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if !wait(for: process, seconds: killGrace), process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Whether the process ended within `seconds`.
    private static func wait(for process: Process, seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= end { return false }
            usleep(20_000)
        }
        return true
    }

    /// Set once to tell the readers and the writer to give up.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Output populated by a background task; read only after `DispatchGroup.wait`.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
