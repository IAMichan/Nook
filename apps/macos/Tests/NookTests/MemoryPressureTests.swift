import XCTest

final class MemoryPressureTests: XCTestCase {
    func testPurgesRunInOrderAndAKeyRegistersOnce() {
        let hub = MemoryPressure()
        let log = Log()
        hub.register("a") { _ in log.add("a") }
        hub.register("b") { level in log.add(level == .critical ? "b!" : "b") }
        hub.register("a") { _ in log.add("a2") }
        hub.purge(.warning)
        hub.purge(.critical)
        XCTAssertEqual(log.items, ["a2", "b", "a2", "b!"])
        hub.unregister("a")
        XCTAssertEqual(hub.registered, ["b"])
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [String] = []
        func add(_ item: String) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }
    }
}
