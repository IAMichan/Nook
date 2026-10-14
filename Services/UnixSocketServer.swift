import Foundation
import Darwin

/// Eén verbinding van het hook-script. Antwoorden kan maar één keer, ook als jouw klik en een time-out
/// tegelijk komen. Verbreekt de agent zelf de verbinding (je antwoordde in de terminal, of de agent stopte),
/// dan hoort Nook dat via `onPeerClosed`, zodat een kaart in de notch meteen kan verdwijnen.
final class HookConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var finished = false
    private var closedBeforeHandler = false
    private var peerClosedHandler: (() -> Void)?
    private var source: DispatchSourceRead?

    init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        if !finished { source?.cancel() }
    }

    /// Begint te letten op het sluiten van de andere kant. De verbinding sluit zichzelf via de cancel-handler.
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

    /// Wordt op de main thread aangeroepen als de agent ophangt voordat Nook antwoordde.
    func onPeerClosed(_ handler: @escaping () -> Void) {
        lock.lock()
        let early = closedBeforeHandler
        peerClosedHandler = early ? nil : handler
        closedBeforeHandler = false
        lock.unlock()
        if early { DispatchQueue.main.async(execute: handler) }
    }

    /// Stuurt het antwoord (of niets) en sluit. Geeft false als er al geantwoord was of de agent al weg is.
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
            // Onverwachte extra data: weggooien, de verbinding blijft open.
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

/// Kleine lokale server waar agents (via hun hook-script) gebeurtenissen naartoe sturen.
/// Alleen jijzelf kunt erbij: het socketbestand is 0600 en elke verbinding wordt op gebruikers-ID gecontroleerd.
final class UnixSocketServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "nl.imdigital.nook.hub.accept")
    private let clientQueue = DispatchQueue(label: "nl.imdigital.nook.hub.client", attributes: .concurrent)
    private let watchQueue = DispatchQueue(label: "nl.imdigital.nook.hub.watch")

    /// Wordt aangeroepen met één regel JSON en de verbinding om (eenmalig) op te antwoorden.
    var onMessage: ((Data, HookConnection) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NookError("Socket maken mislukt.") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw NookError("Pad naar de socket is te lang.")
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
            throw NookError("Socket koppelen mislukt (\(String(cString: strerror(errno)))).")
        }
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            throw NookError("Luisteren op de socket mislukt.")
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

        let connection = HookConnection(fd: fd)
        connection.start(queue: watchQueue)
        handler(buffer, connection)
    }
}
