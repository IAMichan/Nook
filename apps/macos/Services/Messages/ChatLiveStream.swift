import Foundation

/// A live line to Nook's chat helper that `ChatServiceBridge` reads (its `/v1/ws` socket on this Mac): it says which chat
/// changed the moment it does, so the bridge reads that chat now instead of at its next turn, and who is typing where. What
/// changed is read the usual way. Delivery is at most once and nothing is replayed after a drop, so `onDrop` reads everything
/// again once.
@MainActor
final class ChatLiveStream {
    /// A chat (by its id there) has something new: a message, an edit, an emoji, a deletion, a read.
    var onChange: (String) -> Void = { _ in }
    /// Someone is typing in a chat (by its id there), or stopped (`seconds` 0).
    var onTyping: (_ chat: String, _ person: String, _ name: String, _ kind: ChatTypist.Kind, _ seconds: TimeInterval) -> Void
        = { _, _, _, _, _ in }
    /// The line went down: what changed meanwhile is not told.
    var onDrop: () -> Void = {}
    /// The line came up or went down.
    var onLive: (Bool) -> Void = { _ in }

    /// Subscribed and listening.
    private(set) var isLive = false {
        didSet { if isLive != oldValue { onLive(isLive) } }
    }
    private var task: URLSessionWebSocketTask?
    private var listening: Task<Void, Never>?
    private var pinging: Task<Void, Never>?
    /// Counts connections, so a line that went down does not report on the one after it.
    private var generation = 0

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // The line stays open and quiet for long stretches: only the ping below says it is gone.
        configuration.timeoutIntervalForRequest = 24 * 3600
        return URLSession(configuration: configuration)
    }()
    private static let pingGap: Duration = .seconds(30)

    var isConnecting: Bool { task != nil }

    /// Opens the line, unless it is open or opening.
    func connect(_ url: URL, token: String) {
        guard task == nil else { return }
        generation += 1
        let current = generation
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let task = Self.session.webSocketTask(with: request)
        self.task = task
        task.resume()
        listening = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    self?.handle(message, task: task)
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
                if !alive {
                    self?.dropped(current)
                    return
                }
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

    private func handle(_ message: URLSessionWebSocketTask.Message, task: URLSessionWebSocketTask) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        guard let data, let json = ChatJSON.object(data) else { return }
        switch ChatServiceData.event(json) {
        case .ready:
            guard let body = try? JSONSerialization.data(withJSONObject: ChatServiceData.subscribeAll),
                  let text = String(data: body, encoding: .utf8) else { return }
            task.send(.string(text)) { _ in }
        case .subscribed:
            isLive = true
        case .changed(let chat):
            onChange(chat)
        case .typing(let chat, let person, let name, let kind, let seconds):
            onTyping(chat, person, name, kind, seconds)
        case .other:
            break
        }
    }
}
