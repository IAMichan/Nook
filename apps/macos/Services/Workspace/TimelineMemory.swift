import Foundation

/// What each timeline in memory holds, in bytes (`RunEvent.approximateBytes` added up), kept as events come and change.
/// `TimelineEviction` weighs every loaded timeline after each load and every half minute: adding up every event of every
/// timeline each time grew with all that was loaded, while a streaming agent only adds to one.
struct TimelineBytes {
    private var counts: [UUID: Int] = [:]

    /// Every event's bytes added up: what a count must equal.
    static func total(_ events: [RunEvent]) -> Int {
        events.reduce(0) { $0 + $1.approximateBytes }
    }

    /// The timeline's bytes: as counted, or added up now (and kept) when nothing was counted for it.
    mutating func bytes(_ id: UUID, of events: [RunEvent]) -> Int {
        if let known = counts[id] { return known }
        let total = Self.total(events)
        counts[id] = total
        return total
    }

    /// The timeline was put in memory whole (read from disk).
    mutating func loaded(_ id: UUID, _ events: [RunEvent]) {
        counts[id] = Self.total(events)
    }

    /// An event was added to the timeline.
    mutating func appended(_ id: UUID, _ event: RunEvent) {
        counts[id]? += event.approximateBytes
    }

    /// An event of the timeline that held `before` bytes holds `after` now.
    mutating func changed(_ id: UUID, from before: Int, to after: Int) {
        counts[id]? += after - before
    }

    /// The timeline left memory, or changed in a way this did not follow: counted again when next asked.
    mutating func forget(_ id: UUID) {
        counts[id] = nil
    }

    /// Any timeline may have changed: each is counted again when next asked.
    mutating func forgetAll() {
        counts.removeAll()
    }

    func count(_ id: UUID) -> Int? { counts[id] }
}

/// A timeline read back from disk while events were added to it (`WorkspaceManager.append` buffers them until the read is
/// done, instead of reading on the main thread). Each buffered event was handed to the log as it came, so the read may
/// hold it already, possibly before it changed: the buffered version is the newer one.
enum TimelineMerge {
    static func merge(_ loaded: [RunEvent], _ buffered: [RunEvent]) -> [RunEvent] {
        guard !buffered.isEmpty else { return loaded }
        var events = loaded
        var index = Dictionary(loaded.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        for event in buffered {
            if let at = index[event.id] {
                events[at] = event
            } else {
                index[event.id] = events.count
                events.append(event)
            }
        }
        return events
    }
}
