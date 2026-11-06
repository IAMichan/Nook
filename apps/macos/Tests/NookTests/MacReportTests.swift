import XCTest

/// How the Mac is doing, in words.
final class MacReportTests: XCTestCase {
    func testProcessesAddUpPerApp() {
        let ps = """
         85.2 512000 Google Chrome Helper (Renderer)
         20,0 256000 Google Chrome
          3.1 102400 Finder
          0.0  2048 ps
        """
        let apps = MacReport.parseProcesses(ps)
        XCTAssertEqual(apps.first?.name, "Google Chrome")
        XCTAssertEqual(apps.first?.cpu ?? 0, 105.2, accuracy: 0.01)
        XCTAssertEqual(apps.first?.memoryMB ?? 0, 750, accuracy: 0.1)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "Finder"])
    }

    func testWhatStandsOut() {
        var report = MacReport(cpu: 92, memoryUsedGB: 15.1, memoryTotalGB: 16, memoryPressure: 2, thermal: 2,
                               batteryPercent: 9, onPower: false, diskFreeGB: 8, diskTotalGB: 500, uptimeHours: 400)
        report.apps = [MacReport.App(name: "Xcode", cpu: 80, memoryMB: 4_096)]
        let text = report.text
        XCTAssertTrue(text.contains("the processor is very busy, memory is short, the Mac is hot and slowed down, the battery is almost empty, the disk is nearly full"), text)
        XCTAssertTrue(text.contains("Xcode 80% CPU, 4.0 GB"), text)
        XCTAssertTrue(MacReport(cpu: 12, memoryPressure: 1, thermal: 0).text.contains("Nothing unusual"))
    }

    func testNetworkReport() {
        XCTAssertEqual(NetworkReport.parsePublicAddress("fl=1\nip=203.0.113.7\nts=1"), "203.0.113.7")
        XCTAssertNil(NetworkReport.parsePublicAddress("ip="))
        let text = NetworkReport(addresses: [.init(interface: "en0", address: "192.168.1.20")], publicAddress: "203.0.113.7").text
        XCTAssertTrue(text.contains("203.0.113.7"), text)
        XCTAssertTrue(text.contains("en0: 192.168.1.20"), text)
        XCTAssertTrue(NetworkReport().text.contains("could not be read"))
    }
}
