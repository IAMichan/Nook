import Foundation

/// Which rows a sweep takes (`RowSweep`): you press a row's button and drag up or down, and every row of its group between
/// that row and the one under the pointer comes along, top to bottom (as settle sweep).
enum RowSweepRange {
    /// The rows whose frame meets the span from the middle of `origin`'s row to `pointerY`, top to bottom; just `origin`
    /// while the pointer stays on its own row, and nothing when `origin` has no frame.
    static func ids<ID: Hashable>(frames: [ID: CGRect], origin: ID, pointerY: CGFloat) -> [ID] {
        guard let start = frames[origin] else { return [] }
        let low = min(start.midY, pointerY), high = max(start.midY, pointerY)
        return frames.filter { $0.key == origin || ($0.value.maxY >= low && $0.value.minY <= high) }
            .sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
            .map(\.key)
    }
}
