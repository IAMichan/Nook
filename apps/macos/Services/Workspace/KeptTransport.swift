import Foundation
#if canImport(Darwin)
import Darwin
private let streamSocket = SOCK_STREAM
#else
import Glibc
private let streamSocket = Int32(SOCK_STREAM.rawValue)
#endif

// The system's calls, under names the class's own methods do not hide.
private func systemRead(_ fd: Int32, _ buffer: inout [UInt8]) -> Int { read(fd, &buffer, buffer.count) }
private func systemWrite(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int { write(fd, bytes, count) }
private func systemConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ size: socklen_t) -> Int32 { connect(fd, address, size) }

/// A session's agent through its keeper (`SessionKeeper`) instead of as Nook's own child. Stdout comes from the keeper's spool,
/// so `offset` always says how far Nook read; another Nook can attach there later and miss nothing.
final class KeptTransport: ProviderTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let folder: URL
    private let script: String
    private let startOffset: UInt64
    private var descriptor: Int32 = -1
    private var agentPID: Int32 = 0
    private var ended = false
    private var read: UInt64
    private let queue = DispatchQueue(label: "nook.kept-transport")

    /// `offset`: how much of the spool an earlier Nook already read; nil starts a new keeper in `folder`.
    init(folder: URL, script: String, offset: UInt64? = nil) {
        self.folder = folder
        self.script = script
        startOffset = offset ?? 0
        read = offset ?? 0
        attaching = offset != nil
    }

    private let attaching: Bool
    var pid: Int32 { lock.withLock { agentPID } }
    var isRunning: Bool { lock.withLock { descriptor >= 0 && !ended } }
    /// Stdout bytes handed on so far.
    var offset: UInt64 { lock.withLock { read } }

    /// Whether a keeper still answers in `folder`.
    static func isAlive(folder: URL) -> Bool {
        let fd = connect(to: folder.appendingPathComponent("sock").path)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    /// Stops the agent of the keeper in `folder` for good, with nobody attached: it interrupts, terminates, kills, and cleans
    /// up by itself. False when no keeper answers there.
    @discardableResult
    static func stop(folder: URL) -> Bool {
        let fd = connect(to: folder.appendingPathComponent("sock").path)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let frame = SessionKeeper.encode(.stop)
        let sent = frame.withUnsafeBytes { systemWrite(fd, $0.baseAddress!, $0.count) }
        return sent == frame.count
    }

    func start(_ options: SpawnedProcess.Options, onStdout: @escaping @Sendable (Data) -> Void,
               onStderr: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        if !attaching { try launch(options) }
        let fd = Self.connect(to: folder.appendingPathComponent("sock").path)
        guard fd >= 0 else { throw NookError("The session's keeper does not answer.") }
        lock.withLock { descriptor = fd }
        try writeAll(SessionKeeper.attach(offset: startOffset))
        queue.async { [self] in pump(fd, onStdout: onStdout, onStderr: onStderr, onExit: onExit) }
    }

    private func launch(_ options: SpawnedProcess.Options) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = SessionKeeper.arguments(script: script, folder: folder.path, workingDirectory: options.workingDirectory,
                                                    keepsInputOpen: options.keepsInputOpen, executable: options.executable,
                                                    arguments: options.arguments)
        process.environment = options.environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let answer = output.fileHandleForReading.readData(ofLength: 6)
        process.waitUntilExit()
        guard String(decoding: answer, as: UTF8.self).hasPrefix("ready") else { throw NookError("The session's keeper did not start.") }
    }

    private func pump(_ fd: Int32, onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = systemRead(fd, &chunk)
            if count <= 0 { break }
            buffer.append(contentsOf: chunk[0..<count])
            guard let frames = SessionKeeper.decode(&buffer) else { break }
            for frame in frames {
                switch frame.kind {
                case .pid:
                    lock.withLock { agentPID = Int32(String(decoding: frame.payload, as: UTF8.self)) ?? 0 }
                case .stdout:
                    lock.withLock { read += UInt64(frame.payload.count) }
                    onStdout(frame.payload)
                case .stderr:
                    onStderr(frame.payload)
                case .exit:
                    lock.withLock { ended = true }
                    onStdout(Data())
                    onExit(Int32(String(decoding: frame.payload, as: UTF8.self)) ?? 1)
                    try? writeAll(SessionKeeper.encode(.quit))
                    closeSocket()
                    return
                default:
                    break
                }
            }
        }
        // The socket went without an end: the keeper was killed, or Nook let go.
        let lost = lock.withLock { () -> Bool in
            defer { ended = true }
            return descriptor >= 0
        }
        closeSocket()
        if lost {
            onStdout(Data())
            onExit(1)
        }
    }

    private func closeSocket() {
        let fd = lock.withLock { () -> Int32 in
            defer { descriptor = -1 }
            return descriptor
        }
        if fd >= 0 { close(fd) }
    }

    /// Nook goes, the agent stays: only the connection ends.
    func detach() { closeSocket() }

    func write(_ data: Data) throws { try writeAll(SessionKeeper.encode(.stdin, data)) }
    func closeInput() { try? writeAll(SessionKeeper.encode(.closeInput)) }

    @discardableResult
    func signalGroup(_ signal: Int32) -> Bool {
        (try? writeAll(SessionKeeper.encode(.signal, Data(String(signal).utf8)))) != nil
    }

    /// Stops the agent; the keeper sees it through and cleans up, also when Nook is gone by then.
    func stopForGood() { try? writeAll(SessionKeeper.encode(.stop)) }

    func hold() {}
    func release() {}

    private func writeAll(_ data: Data) throws {
        let fd = lock.withLock { descriptor }
        guard fd >= 0 else { throw NookError("The session's keeper is gone.") }
        var sent = 0
        try data.withUnsafeBytes { bytes in
            while sent < bytes.count {
                let count = systemWrite(fd, bytes.baseAddress! + sent, bytes.count - sent)
                guard count > 0 else { throw NookError("The session's keeper is gone.") }
                sent += count
            }
        }
    }

    private static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, streamSocket, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: address.sun_path) - 1))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(fd, $0, size) } }
        guard result == 0 else { close(fd); return -1 }
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }
}
