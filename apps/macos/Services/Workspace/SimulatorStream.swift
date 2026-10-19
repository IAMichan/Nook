import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One simulator, live: its screen as H.264 from the hub (`stream.avcc`, decoded by the screen
/// view), or as MJPEG when that cannot be decoded, and your touches, buttons, keys and rotation over its input
/// WebSocket. Input goes only once the hub has admitted it and the device takes input; a dropped connection comes back
/// after a second.
@MainActor
final class SimulatorStream: ObservableObject {
    @Published private(set) var frame: Data?
    @Published private(set) var config: DeviceHub.ScreenConfig?
    @Published private(set) var inputReady = false
    @Published private(set) var problem: String?
    /// The screen comes as H.264 (the screen view decodes `onVideo`); false: as MJPEG pictures in `frame`.
    @Published private(set) var usesH264 = false

    /// H.264 setup and frames for the screen view, on the main thread; `onVideoReset` before a new stream starts.
    var onVideo: ((AvccChunk) -> Void)?
    var onVideoReset: (() -> Void)?

    private(set) var udid: String?
    private var receiver: MjpegReceiver?
    private var socket: URLSessionWebSocketTask?
    private var admitted = false
    private var noVideo: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation = 0
    private var socketOpened = false
    private var video: ByteStreamReceiver?
    private var videoStall: Task<Void, Never>?
    /// This device's H.264 could not be decoded here: MJPEG from now on.
    private var h264Failed = false

    func start(_ udid: String) {
        stop()
        h264Failed = false
        self.udid = udid
        generation += 1
        connect(generation)
    }

    func stop() {
        generation += 1
        receiver?.cancel()
        receiver = nil
        stopVideo()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        noVideo?.cancel()
        retry?.cancel()
        admitted = false
        inputReady = false
        usesH264 = false
        frame = nil
        config = nil
        problem = nil
        udid = nil
    }

    /// The MJPEG picture first: it starts the capture serve-sim needs before it takes input (H.264 does not reliably
    /// start it). Then the input socket, and H.264 in place of the MJPEG stream unless this device fell back to MJPEG.
    private func connect(_ generation: Int) {
        guard let udid, let streamURL = DeviceHubService.shared.url(DeviceHub.mjpegPath(udid: udid)) else { return }
        problem = nil
        socketOpened = false
        onVideoReset?()
        let receiver = MjpegReceiver(url: streamURL) { [weak self] jpeg in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                if !self.usesH264 { self.frame = jpeg }
                self.noVideo?.cancel()
                if !self.socketOpened {
                    self.socketOpened = true
                    self.openSocket(generation)
                    if !self.h264Failed {
                        self.receiver?.cancel()
                        self.receiver = nil
                        self.startVideo(generation)
                    }
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

    // MARK: H.264

    private func startVideo(_ generation: Int) {
        guard let udid, let url = DeviceHubService.shared.url(DeviceHub.avccPath(udid: udid)) else { return }
        stopVideo()
        var demuxer = AvccDemuxer()
        let lock = NSLock()
        let video = ByteStreamReceiver(url: url) { [weak self] data in
            lock.lock()
            let chunks = demuxer.push(data)
            lock.unlock()
            Task { @MainActor in self?.received(chunks, generation) }
        } onEnd: { [weak self] in
            Task { @MainActor in self?.dropped(generation) }
        }
        self.video = video
        video.start()
        armStall(generation)
    }

    private func stopVideo() {
        video?.cancel()
        video = nil
        videoStall?.cancel()
        videoStall = nil
    }

    private func received(_ chunks: [AvccChunk], _ generation: Int) {
        guard self.generation == generation, video != nil else { return }
        armStall(generation)
        for chunk in chunks {
            switch chunk.kind {
            case .seed:
                // A still until the first decoded frame.
                if !usesH264 { frame = chunk.payload }
            case .description:
                usesH264 = true
                onVideo?(chunk)
            case .keyframe, .delta:
                onVideo?(chunk)
            }
        }
    }

    /// An H.264 body can stay open after the helper stops producing frames: 15 s without data reconnects.
    private func armStall(_ generation: Int) {
        videoStall?.cancel()
        videoStall = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.problem = tr("sim.stream.stalled")
            self.dropped(generation)
        }
    }

    /// The screen view could not decode this stream: MJPEG from now on, for this device.
    func decoderFailed() {
        guard !h264Failed else { return }
        h264Failed = true
        stopVideo()
        usesH264 = false
        onVideoReset?()
        let generation = self.generation
        guard let udid, let streamURL = DeviceHubService.shared.url(DeviceHub.mjpegPath(udid: udid)) else { return }
        let receiver = MjpegReceiver(url: streamURL) { [weak self] jpeg in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.frame = jpeg
            }
        } onEnd: { [weak self] in
            Task { @MainActor in self?.dropped(generation) }
        }
        self.receiver = receiver
        receiver.start()
    }

    /// The decoder fell behind: a new subscription makes serve-sim start with a fresh keyframe.
    func resubscribeVideo() {
        guard video != nil, !h264Failed else { return }
        onVideoReset?()
        startVideo(generation)
    }

    /// Lost: everything again after a second (the picture first, as before).
    private func dropped(_ generation: Int) {
        guard self.generation == generation, udid != nil else { return }
        stopVideo()
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

/// A long HTTP body as it arrives, piece by piece (the H.264 stream).
final class ByteStreamReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let onData: (Data) -> Void
    private let onEnd: () -> Void
    private var session: URLSession?
    private let lock = NSLock()
    private var cancelled = false

    init(url: URL, onData: @escaping (Data) -> Void, onEnd: @escaping () -> Void) {
        self.url = url
        self.onData = onData
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

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !isCancelled { onData(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !isCancelled { onEnd() }
    }
}
