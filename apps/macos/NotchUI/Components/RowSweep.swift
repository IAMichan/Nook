import AppKit
import SwiftUI

/// Press a row's button and drag up or down to take every row of its group in between along; Escape cancels.
/// Shared by the Agents list (Settle, Un-settle and Wake on many sessions) and the pull request lists
/// (Close on many requests). Rows tell it where they are with `sweepRow`, the button that starts it carries `sweeps`;
/// what the sweep does with the rows is the caller's.
@MainActor
final class RowSweep<ID: Hashable>: ObservableObject {
    /// Where each row that can be swept is (global coordinates) and the group it sweeps with, such as a section of the
    /// list. Not published: every scroll sets it.
    var rows: [ID: (group: String, frame: CGRect)] = [:]
    /// The rows the drag covers now, top to bottom; the rows light up from it.
    @Published private(set) var swept: [ID] = []
    /// The row whose button the drag started on, while it lasts.
    @Published private(set) var origin: ID?
    private var cancelled = false
    private var escapeMonitor: Any?

    func drag(from origin: ID, at point: CGPoint) {
        guard !cancelled else { return }
        if self.origin == nil {
            self.origin = origin
            watchEscape()
        }
        let group = rows[origin]?.group
        let frames = rows.filter { $0.value.group == group }.mapValues(\.frame)
        let next = RowSweepRange.ids(frames: frames, origin: origin, pointerY: point.y)
        if next != swept { swept = next }
    }

    /// The drag ended: the rows it swept when it took more than its own row (one row is the button's own click), else none.
    func end() -> [ID] {
        let result = cancelled || swept.count < 2 ? [] : swept
        reset()
        return result
    }

    /// Escape: the drag sweeps nothing more and ends without taking anything.
    func cancel() {
        cancelled = true
        if !swept.isEmpty { swept = [] }
    }

    private func reset() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        cancelled = false
        if !swept.isEmpty { swept = [] }
        if origin != nil { origin = nil }
    }

    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
    }
}

extension View {
    /// Makes this row one a sweep can take: it says where it is, in `group` (a sweep stays within the group it started in).
    func sweepRow<ID: Hashable>(_ sweep: RowSweep<ID>, id: ID, group: String = "") -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            sweep.rows[id] = (group, frame)
        }
        .onDisappear { sweep.rows[id] = nil }
    }

    /// Makes this button start a sweep from row `id` when it is pressed and dragged; `onEnd` gets the rows swept (two or
    /// more) when the drag ends, and is not called for a plain click or a cancelled sweep. The drag goes before the row's
    /// own (dragging a session onto a composer), and a click without movement stays the button's.
    func sweeps<ID: Hashable>(_ sweep: RowSweep<ID>, from id: ID, enabled: Bool = true,
                              onEnd: @escaping ([ID]) -> Void) -> some View {
        modifier(RowSweepGesture(sweep: sweep, id: id, enabled: enabled, onEnd: onEnd))
    }
}

/// The drag behind `sweeps`. It ends through a gesture state, which also resets when the drag is cancelled, so a sweep
/// never stays half started; a button that goes away mid-drag ends its sweep too.
private struct RowSweepGesture<ID: Hashable>: ViewModifier {
    let sweep: RowSweep<ID>
    let id: ID
    let enabled: Bool
    let onEnd: ([ID]) -> Void
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(enabled ? DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { value in sweep.drag(from: id, at: value.location) } : nil)
            .onChange(of: dragging) { _, now in
                guard !now else { return }
                let ids = sweep.end()
                if !ids.isEmpty { onEnd(ids) }
            }
            .onDisappear { if sweep.origin == id { _ = sweep.end() } }
    }
}
