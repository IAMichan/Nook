import XCTest

/// `TimelineBytes` keeps what each timeline holds as events come and change, instead of adding up every event of every
/// loaded timeline after each load. Whatever happens to the timelines, a count must equal adding them up again.
final class TimelineMemoryTests: XCTestCase {
    private func event(_ length: Int) -> RunEvent {
        RunEvent(kind: .assistant, text: String(repeating: "é", count: length))
    }

    func testCountsMatchAddingEveryEventUp() {
        var generator = SystemRandomNumberGenerator()
        let ids = (0..<4).map { _ in UUID() }
        var timelines: [UUID: [RunEvent]] = [:]
        var bytes = TimelineBytes()
        for _ in 0..<2_000 {
            let id = ids.randomElement(using: &generator)!
            switch Int.random(in: 0..<7, using: &generator) {
            case 0:
                // Read from disk.
                let loaded = (0..<Int.random(in: 0...20, using: &generator)).map { _ in event(Int.random(in: 0...300, using: &generator)) }
                timelines[id] = loaded
                bytes.loaded(id, loaded)
            case 1, 2:
                // Appended (to a timeline in memory, as `append` does after reading it back).
                guard timelines[id] != nil else { continue }
                let added = event(Int.random(in: 0...300, using: &generator))
                timelines[id]!.append(added)
                bytes.appended(id, added)
            case 3, 4:
                // A streamed event grows, or a tool's output comes in.
                guard let list = timelines[id], !list.isEmpty else { continue }
                let index = Int.random(in: 0..<list.count, using: &generator)
                let before = list[index].approximateBytes
                if Bool.random(using: &generator) {
                    timelines[id]![index].text += String(repeating: "x", count: Int.random(in: 0...80, using: &generator))
                } else {
                    timelines[id]![index].output = String(repeating: "o", count: Int.random(in: 0...80, using: &generator))
                }
                bytes.changed(id, from: before, to: timelines[id]![index].approximateBytes)
            case 5:
                // Evicted.
                timelines[id] = nil
                bytes.forget(id)
            default:
                // A change the counts do not follow (a rollback): all are counted again.
                if let list = timelines[id], !list.isEmpty { timelines[id]!.removeLast() }
                bytes.forgetAll()
            }
            for (key, list) in timelines {
                XCTAssertEqual(bytes.bytes(key, of: list), TimelineBytes.total(list))
            }
        }
    }

    func testAnUnknownTimelineIsCountedWhenAskedAndThenFollowed() {
        let id = UUID()
        var bytes = TimelineBytes()
        var list = [event(10), event(20)]
        // Appending to a timeline nothing counted yet leaves it uncounted, not wrong.
        bytes.appended(id, event(5))
        XCTAssertNil(bytes.count(id))
        XCTAssertEqual(bytes.bytes(id, of: list), TimelineBytes.total(list))
        let added = event(30)
        list.append(added)
        bytes.appended(id, added)
        XCTAssertEqual(bytes.count(id), TimelineBytes.total(list))
    }
}
