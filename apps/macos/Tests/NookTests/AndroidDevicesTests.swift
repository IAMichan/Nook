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

/// Against a real device, when one runs here; skipped everywhere else.
final class AndroidDeviceIntegrationTests: XCTestCase {
    func testARunningDeviceIsFoundAndPhotographed() throws {
        guard AndroidDevices.adb != nil else { throw XCTSkip("No Android SDK here.") }
        let devices = AndroidDevices.all()
        guard let device = devices.first(where: \.running), let serial = device.serial else { throw XCTSkip("No device runs.") }
        XCTAssertTrue(AndroidDevices.isAndroid(device.id))
        let picture = try XCTUnwrap(AndroidDevices.screenshot(serial: serial))
        XCTAssertEqual(Array(picture.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "a PNG")
        XCTAssertGreaterThan(picture.count, 10_000)
    }
}
