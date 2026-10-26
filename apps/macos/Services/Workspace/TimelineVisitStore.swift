import Foundation

/// Keeps where you left each session's conversation and when you last looked at it, across launches. The rules live in
/// `TimelineVisits` and `TimelineLanding`; this only reads and writes the file, a moment after the last change.
@MainActor
final class TimelineVisitStore {
    static let shared = TimelineVisitStore()

    private(set) var visits = TimelineVisits()
    private let url: URL
    private var pending: Task<Void, Never>?

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
            guard let data = try? JSONEncoder().encode(visits) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
