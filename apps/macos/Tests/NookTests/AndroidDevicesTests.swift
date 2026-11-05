import XCTest

final class AndroidDevicesTests: XCTestCase {
    func testRunningDevicesOnlyWhenUsable() {
        let output = """
        List of devices attached
        emulator-5554          device product:sdk_gphone model:Pixel_8 device:emu64a transport_id:1
        R58M1234               unauthorized usb:1
        ZY22                   offline
        """
        let devices = AndroidDevices.parseRunning(output)
        XCTAssertEqual(devices, [AndroidDevice(id: "android:emulator-5554", name: "Pixel 8", running: true, serial: "emulator-5554")])
    }

    func testVirtualDevicesSkipLogsAndWhatRuns() {
        let output = "INFO    | Storing crashdata in: /tmp\nPixel_8\nPixel_Tablet\n"
        XCTAssertEqual(AndroidDevices.parseVirtual(output, runningNames: ["Pixel_8"]).map(\.id), ["android-avd:Pixel_Tablet"])
    }

    func testSdkFolders() {
        XCTAssertEqual(AndroidDevices.sdkFolders(environment: ["ANDROID_HOME": "/a"], home: "/h"), ["/a", "/h/Library/Android/sdk"])
    }

    func testIds() {
        XCTAssertTrue(AndroidDevices.isAndroid("android:x"))
        XCTAssertTrue(AndroidDevices.isAndroid("android-avd:x"))
        XCTAssertFalse(AndroidDevices.isAndroid("ABCD-1234"))
    }
}
