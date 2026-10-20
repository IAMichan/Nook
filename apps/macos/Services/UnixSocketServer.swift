import Foundation
import Darwin

/// A single connection from the hook script. Replying can only happen once, even if your click and a timeout
/// occur at the same time. If the agent itself disconnects (you answered in the terminal, or the agent exited),
/// Nook learns this via `onPeerClosed`, allowing a card in the notch to be dismissed immediately.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    /// The process that connected (the hook script) and the ones it was started from, nearest first; empty when unknown.
    let lineage: [Int32]
    private let lock = NSLock()
    private var finished = false
    private var closedBeforeHandler = false
    private var peerClosedHandler: (() -> Void)?
    private var source: DispatchSourceRead?

    init(fd: Int32, lineage: [Int32] = []) {
        self.fd = fd
        self.lineage = lineage
    }

    deinit {
        if !finished { source?.cancel() }
    }

    /// Starts monitoring the peer for disconnect. The connection closes its file descriptor via the cancel handler.
    func start(queue: DispatchQueue) {
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished
    }

    /// Invoked on the main thread if the agent disconnects before Nook responded.
    func onPeerClosed(_ handler: @escaping () -> Void) {
        lock.lock()
        let early = closedBeforeHandler
        peerClosedHandler = early ? nil : handler
        closedBeforeHandler = false
        lock.unlock()
        if early { DispatchQueue.main.async(execute: handler) }
    }

    /// Sends the reply (or nothing) and closes. Returns false if already answered or if the agent has disconnected.
    @discardableResult
    func reply(_ response: Data?) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        peerClosedHandler = nil
        lock.unlock()

        if var data = response {
            data.append(10)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, base + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
        source?.cancel()
        return true
    }

    private func readable() {
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if peeked > 0 {
            // Unexpected extra data: discard, connection remains open.
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = read(fd, &buffer, buffer.count)
            return
        }
        if peeked < 0, errno == EAGAIN || errno == EINTR { return }

        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let handler = peerClosedHandler
        peerClosedHandler = nil
        if handler == nil { closedBeforeHandler = true }
        lock.unlock()

        source?.cancel()
        if let handler { DispatchQueue.main.async(execute: handler) }
    }
}

/// Lightweight local server where agents send events (via their hook script).
/// Restricted to the current user: socket file is 0600 and every connection is verified against the user ID.
final class UnixSocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "nl.imdigital.nook.hub.accept")
    private let clientQueue = DispatchQueue(label: "nl.imdigital.nook.hub.client", attributes: .concurrent)
    private let watchQueue = DispatchQueue(label: "nl.imdigital.nook.hub.watch")

    /// Called with one line of JSON and the connection to reply on (once).
    var onMessage: ((Data, HookConnection) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NookError("Failed to create socket.") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NookError("Socket path is too long.")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() {
                raw[index] = UInt8(bitPattern: byte)
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            close(fd)
            throw NookError("Failed to bind socket (\(String(cString: strerror(errno)))).")
        }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw NookError("Failed to listen on socket.")
        }
        listenFD = fd
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            clientQueue.async { [weak self] in self?.handle(client) }
        }
    }

    /// The process on the other end of the socket.
    private static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// `pid` and its parents, nearest first: the hook script, the shell that ran it, the agent, its terminal. Read
    /// while the hook still runs, since the script and its shell are gone a moment later.
    private static func lineage(of pid: pid_t?, limit: Int = 6) -> [Int32] {
        var chain: [Int32] = []
        var next = pid
        while let current = next, current > 1, chain.count < limit, !chain.contains(current) {
            chain.append(current)
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            next = pid_t(info.pbi_ppid)
        }
        return chain
    }

    private func handle(_ fd: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while buffer.count < 4_000_000 {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
            if chunk[0..<count].contains(10) { break }
        }

        guard !buffer.isEmpty, let handler = onMessage else {
            close(fd)
            return
        }

        let connection = HookConnection(fd: fd, lineage: Self.lineage(of: Self.peerPID(fd)))
        connection.start(queue: watchQueue)
        handler(buffer, connection)
    }
}
