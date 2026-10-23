import XCTest

final class ResourceUsageTests: XCTestCase {
    private func sample(_ pid: Int32, parent: Int32, started: UInt64 = 1, cpu: UInt64, memory: UInt64 = 100 << 20) -> ProcessSample {
        ProcessSample(pid: pid, parent: parent, started: started, cpuNanoseconds: cpu, memoryBytes: memory)
    }

    func testTheTreeHoldsTheAgentAndWhatItStarted() {
        let all = [sample(1, parent: 0, cpu: 0), sample(10, parent: 1, cpu: 0), sample(11, parent: 10, cpu: 0),
                   sample(12, parent: 11, cpu: 0), sample(20, parent: 1, cpu: 0)]
        XCTAssertEqual(Set(ResourceMeter.tree(root: 10, in: all).map(\.pid)), [10, 11, 12])
        XCTAssertEqual(ResourceMeter.tree(root: 99, in: all), [])
    }

    func testCPUIsMeasuredBetweenTwoReadings() {
        var meter = ResourceMeter()
        XCTAssertNil(meter.measure([sample(10, parent: 1, cpu: 1_000_000_000)], at: 100))
        // One second of CPU over two seconds: 50 %; a child that started in between counts all of its time.
        let usage = meter.measure([sample(10, parent: 1, cpu: 1_500_000_000), sample(11, parent: 10, cpu: 500_000_000)], at: 102)
        XCTAssertEqual(usage?.cpuPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(usage?.processes, 2)
        XCTAssertEqual(usage?.memoryBytes, 200 << 20)
    }

    func testAReusedPidIsANewProcess() {
        var meter = ResourceMeter()
        _ = meter.measure([sample(10, parent: 1, started: 1, cpu: 9_000_000_000)], at: 0)
        let usage = meter.measure([sample(10, parent: 1, started: 2, cpu: 1_000_000_000)], at: 1)
        XCTAssertEqual(usage?.cpuPercent ?? 0, 100, accuracy: 0.001)
    }

    func testLabels() {
        XCTAssertEqual(ResourceUsage(cpuPercent: 4.25, memoryBytes: 340 << 20, processes: 1).label, "4.2 % · 340 MB")
        XCTAssertEqual(ResourceUsage(cpuPercent: 212.6, memoryBytes: 3 << 30, processes: 9).label, "213 % · 3.0 GB")
    }
}
