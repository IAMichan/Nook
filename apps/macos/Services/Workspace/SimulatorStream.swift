import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One simulator, live (as viewer): its screen from the hub's MJPEG stream, and your touches, buttons, keys and
/// rotation over its input WebSocket. Input goes only once the hub has admitted it and the device takes input; a
/// dropped connection comes back after a second.
@MainActor
final class SimulatorStream: ObservableObject {
    @Published private(set) var frame: Data?
    @Published private(set) var config: DeviceHub.ScreenConfig?
    @Published private(set) var inputReady = false
    @Published private(set) var problem: String?

    private(set) var udid: String?
    private var receiver: MjpegReceiver?
    private var socket: URLSessionWebSocketTask?
    private var admitted = false
    private var noVideo: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = 0
    private var socketOpened = false

    func start(_ udid: String) {
        stop()
        self.udid = udid
        generation += 1
        connect(generation)
    }

    func stop() {
        generation += 1
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        noVideo?.cancel()
        retry?.cancel()
        admitted = false
        inputReady = false
        frame = nil
        config = nil
        problem = nil
        udid = nil
    }

    /// The picture first (it starts the capture serve-sim needs before it takes input), then the input socket.
    private func connect(_ generation: Int) {
        guard let udid, let streamURL = DeviceHubService.shared.url(DeviceHub.mjpegPath(udid: udid)) else { return }
        problem = nil
        socketOpened = false
        let receiver = MjpegReceiver(url: streamURL) { [weak self] jpeg in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.frame = jpeg
                self.noVideo?.cancel()
                if !self.socketOpened {
                    self.socketOpened = true
                    self.openSocket(generation)
                }
            }
        } onEnd: { [weak self] in
            Task { @MainActor in self?.dropped(generation) }
        }
        self.receiver = receiver
        receiver.start()
        noVideo?.cancel()
        noVideo = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.generation == generation, self.frame == nil else { return }
            self.problem = tr("sim.stream.noVideo")
        }
    }

    private func openSocket(_ generation: Int) {
        guard let udid, let url = DeviceHubService.shared.url(DeviceHub.inputPath(udid: udid), websocket: true) else { return }
        admitted = false
        inputReady = false
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        receive(socket, generation)
    }

    private func receive(_ socket: URLSessionWebSocketTask, _ generation: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == generation, self.socket === socket else { return }
                switch result {
                case .failure:
                    self.dropped(generation)
                case .success(let message):
                    if case .data(let data) = message { self.handle(DeviceHub.serverMessage(data)) }
                    self.receive(socket, generation)
                }
            }
        }
    }

    private func handle(_ message: DeviceHub.ServerMessage) {
        switch message {
        case .admitted: admitted = true
        case .config(let config):
            self.config = config
            if config.inputUnavailable { problem = tr("sim.stream.inputUnavailable") }
        case .other: break
        }
        inputReady = admitted && config?.inputUnavailable != true
    }

    /// Lost: everything again after a second (the picture first, as before).
    private func dropped(_ generation: Int) {
        guard self.generation == generation, udid != nil else { return }
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        admitted = false
        inputReady = false
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.connect(generation)
        }
    }

    // MARK: Input

    private func send(_ data: Data) {
        guard inputReady, let socket else { return }
        socket.send(.data(data)) { _ in }
    }

    /// A touch at a point of the picture as shown (0…1 each way).
    func touch(_ phase: DeviceHub.Touch, x: Double, y: Double) {
        let point = DeviceHub.devicePoint(x: x, y: y, config: config)
        send(DeviceHub.touchFrame(phase, x: point.x, y: point.y))
    }

    /// A trackpad scroll as a swipe from where the pointer is.
    func swipe(dx: Double, dy: Double, at point: (x: Double, y: Double)) {
        let path = DeviceHub.swipe(dx: dx, dy: dy, from: point)
        guard let first = path.first, let last = path.last else { return }
        touch(.begin, x: first.x, y: first.y)
        for step in path.dropFirst().dropLast() { touch(.move, x: step.x, y: step.y) }
        touch(.end, x: last.x, y: last.y)
    }

    func press(_ button: DeviceHub.Button) { send(DeviceHub.buttonFrame(button)) }

    func key(down: Bool, keyCode: UInt16) {
        guard let usage = DeviceHub.hidUsage[keyCode] else { return }
        send(DeviceHub.keyFrame(down: down, usage: usage))
    }

    func rotate() {
        send(DeviceHub.orientationFrame((config?.orientation ?? .portrait).next))
    }
}

/// The MJPEG stream as it arrives, cut into pictures; only the newest is handed on.
final class MjpegReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let onFrame: (Data) -> Void
    private let onEnd: () -> Void
    private var parser = MjpegParser()
    private var session: URLSession?
    private let lock = NSLock()
    private var cancelled = false

    init(url: URL, onFrame: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
        self.url = url
        self.onFrame = onFrame
        self.onEnd = onEnd
    }

    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: url).resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let frames = cancelled ? [] : parser.feed(data)
        lock.unlock()
        if let newest = frames.last { onFrame(newest) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if !wasCancelled { onEnd() }
    }
}
