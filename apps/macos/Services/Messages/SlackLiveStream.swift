import Foundation

/// Slack's real-time line, as Slack's own clients hold it: `rtm.connect` hands out a socket that says the moment a
/// message comes in, is edited, deleted or gets an emoji, who is typing, and when a conversation was read elsewhere
/// (`SlackData.LiveEvent`). `SlackBridge` reads what changed the usual way, so the line only says where to look; the
/// same shape as the chat helper's line (`ChatLiveStream`). Delivery is at most once and nothing is replayed after a
/// drop, so `onDrop` reads everything again once. A sign-in Slack hands no line to (a pasted token of a newer Slack
/// app) keeps reading on its turns.
@MainActor
final class SlackLiveStream {
    var onEvent: (SlackData.LiveEvent) -> Void = { _ in }
    /// The line went down: what changed meanwhile is not told.
    var onDrop: () -> Void = {}

    /// Said hello and listening.
    private(set) var isLive = false
    private var task: URLSessionWebSocketTask?
    private var listening: Task<Void, Never>?
    private var pinging: Task<Void, Never>?
    /// Counts connections, so a line that went down does not report on the one after it.
    private var generation = 0
    /// Each ping carries a number of its own, as Slack asks.
    private var pingID = 0

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The line stays open and quiet for long stretches: only the ping below says it is gone.
        configuration.timeoutIntervalForRequest = 24 * 3600
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
    private static let pingGap: Duration = .seconds(30)

    var isConnecting: Bool { task != nil }

    /// Opens the line at `url` (from `rtm.connect`), with the sign-in's headers (the website's `d` cookie), unless it
    /// is open or opening.
    func connect(_ url: URL, headers: [String: String]) {
        guard task == nil else { return }
        generation += 1
        let current = generation
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let task = Self.session.webSocketTask(with: request)
        self.task = task
        task.resume()
        listening = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handle(message, connection: current)
                } catch {
                    self?.dropped(current)
                    return
                }
            }
        }
        pinging = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingGap)
                guard !Task.isCancelled else { return }
                let alive = await withCheckedContinuation { continuation in
                    task.sendPing { continuation.resume(returning: $0 == nil) }
                }
                guard alive, let self else {
                    self?.dropped(current)
                    return
                }
                // Slack's own keep-alive too: a line without it is closed after a while.
                self.pingID += 1
                task.send(.string("{\"id\":\(self.pingID),\"type\":\"ping\"}")) { _ in }
            }
        }
    }

    func disconnect() {
        generation += 1
        close()
    }

    private func close() {
        listening?.cancel()
        pinging?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        listening = nil
        pinging = nil
        task = nil
        isLive = false
    }

    private func dropped(_ connection: Int) {
        guard connection == generation, task != nil else { return }
        let wasLive = isLive
        close()
        if wasLive { onDrop() }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, connection: Int) {
        guard connection == generation else { return }
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        guard let data, let json = ChatJSON.object(data) else { return }
        let event = SlackData.liveEvent(json)
        switch event {
        case .hello:
            isLive = true
        case .goodbye:
            // Slack moves the line: the next read opens a new one, and reads what was missed.
            dropped(connection)
            return
        default:
            break
        }
        onEvent(event)
    }
}
