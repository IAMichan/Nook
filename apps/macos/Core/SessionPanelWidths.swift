import Foundation

/// How wide each session's side panel in the Agents tab is, by its page id (`PanelViewModel.selectedAgentID`): dragging
/// the panel wider in one session leaves the others as they were. A session you never resized opens at the usual width.
/// Kept across launches, for the sessions used most recently (`limit`).
struct SessionPanelWidths: Equatable {
    /// The most sessions remembered; the one resized longest ago goes first.
    static let limit = 200

    /// Widths by session id, and the ids from resized longest ago to most recently.
    private(set) var widths: [String: Double] = [:]
    private(set) var order: [String] = []

    init() {}

    /// Reads what `encoded` wrote; anything else gives an empty store.
    init(encoded: [String: Any]?) {
        guard let encoded,
              let widths = encoded["widths"] as? [String: Double],
              let order = encoded["order"] as? [String] else { return }
        self.order = order.filter { widths[$0] != nil }
        self.widths = widths.filter { self.order.contains($0.key) }
    }

    var encoded: [String: Any] { ["widths": widths, "order": order] }

    /// The width `session`'s side panel was left at, or `fallback` when it was never resized.
    func width(for session: String, fallback: Double) -> Double {
        widths[session] ?? fallback
    }

    mutating func set(_ width: Double, for session: String) {
        widths[session] = width
        order.removeAll { $0 == session }
        order.append(session)
        while order.count > Self.limit {
            widths[order.removeFirst()] = nil
        }
    }

    /// The conversation under `old` goes on as `new` (a session that started, one Nook took over): it keeps its width.
    mutating func move(from old: String, to new: String) {
        guard old != new, let width = widths[old] else { return }
        forget(old)
        set(width, for: new)
    }

    mutating func forget(_ session: String) {
        widths[session] = nil
        order.removeAll { $0 == session }
    }
}
