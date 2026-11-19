import Foundation

/// Keeps where you left each session's conversation and when you last looked at it, across launches. The rules live in
/// `TimelineVisits` and `TimelineLanding`; this only reads and writes the file, a moment after the last change.
@MainActor
final class TimelineVisitStore {
    static let shared = TimelineVisitStore()

    private(set) var visits = TimelineVisits()
    private let url: URL
    private var pending: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "ai.nook.timeline-visits", qos: .utility)

    init(url: URL = NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("visits.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(TimelineVisits.self, from: data) {
            visits = stored
        }
    }

    func visit(for sessionID: String) -> TimelineVisit? { visits.visit(for: sessionID) }

    func remember(sessionID: String, visit: TimelineVisit) {
        visits.remember(sessionID: sessionID, visit: visit)
        scheduleWrite()
    }

    private func scheduleWrite() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            pending = nil
            writeAsync()
        }
    }

    /// Writes a pending visit right away and drains any in-flight save before termination.
    func flush() {
        let hadPending = pending != nil
        pending?.cancel()
        pending = nil
        if hadPending {
            let snapshot = visits
            let url = url
            saveQueue.sync { Self.persist(snapshot, to: url) }
        } else {
            saveQueue.sync {}
        }
    }

    private func writeAsync() {
        let snapshot = visits
        let url = url
        saveQueue.async { Self.persist(snapshot, to: url) }
    }

    private nonisolated static func persist(_ snapshot: TimelineVisits, to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
