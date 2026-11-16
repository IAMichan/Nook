import XCTest

final class MusicOutputsTests: XCTestCase {
    // MARK: This Mac

    func testFourCharacterCodes() {
        XCTAssertEqual(MusicOutputs.fourCC("bltn"), 0x626C_746E)
        XCTAssertEqual(MusicOutputs.fourCC("usb "), 0x7573_6220)
    }

    func testMacKindFollowsTransportAndName() {
        XCTAssertEqual(MusicOutputs.macKind(transport: MusicOutputs.builtIn, name: "MacBook Pro Speakers"), .speaker)
        XCTAssertEqual(MusicOutputs.macKind(transport: MusicOutputs.builtIn, name: "External Headphones"), .headphones)
        XCTAssertEqual(MusicOutputs.macKind(transport: MusicOutputs.bluetooth, name: "Sam's AirPods Pro"), .headphones)
        XCTAssertEqual(MusicOutputs.macKind(transport: MusicOutputs.bluetooth, name: "JBL Flip 6"), .bluetooth)
        XCTAssertEqual(MusicOutputs.macKind(transport: MusicOutputs.hdmi, name: "LG UltraFine"), .display)
        XCTAssertEqual(MusicOutputs.macKind(transport: MusicOutputs.usb, name: "Scarlett 2i2"), .speaker)
    }

    func testAirPlayAndIdleVirtualDevicesAreNotListedForTheMac() {
        XCTAssertFalse(MusicOutputs.listsMacOutput(transport: MusicOutputs.airPlay, active: true))
        XCTAssertFalse(MusicOutputs.listsMacOutput(transport: MusicOutputs.virtual, active: false))
        XCTAssertTrue(MusicOutputs.listsMacOutput(transport: MusicOutputs.virtual, active: true))
        XCTAssertTrue(MusicOutputs.listsMacOutput(transport: MusicOutputs.builtIn, active: false))
    }

    func testMacOutputsSortTheActiveOneFirstThenThisMacsOwn() {
        let outputs = [
            MusicOutput(route: .mac(3), name: "Studio Display", kind: .display, active: false),
            MusicOutput(route: .mac(2), name: "JBL Flip 6", kind: .bluetooth, active: true),
            MusicOutput(route: .mac(1), name: "MacBook Pro Speakers", kind: .speaker, active: false),
        ]
        XCTAssertEqual(MusicOutputs.sorted(outputs).map(\.name), ["JBL Flip 6", "MacBook Pro Speakers", "Studio Display"])
    }

    // MARK: Music

    func testAirPlayDevicesLeaveOutThisMacAndUnavailableOnes() {
        let raw = [
            ["Computer", "computer", "true", "true", "100"],
            ["Living room", "HomePod", "false", "true", "40"],
            ["Bedroom TV", "Apple TV", "true", "true", "missing value"],
            ["Garden", "AirPlay device", "false", "false", "50"],
        ].map { $0.joined(separator: "\u{1F}") }.joined(separator: "\u{1E}") + "\u{1E}"
        let devices = MusicOutputs.airPlayDevices(raw)
        XCTAssertEqual(devices.map(\.name), ["Living room", "Bedroom TV"])
        XCTAssertEqual(devices.map(\.kind), [.speaker, .tv])
        XCTAssertEqual(devices.map(\.active), [false, true])
        XCTAssertEqual(devices.first?.volume, 40)
        XCTAssertNil(devices.last?.volume)
        XCTAssertEqual(devices.first?.route, .airPlay("Living room"))
        XCTAssertTrue(MusicOutputs.airPlayDevices("").isEmpty)
    }

    func testSelectingAirPlayEscapesNamesAndEmptyGoesBackToTheMac() {
        let script = MusicOutputs.selectAirPlayScript(["Mia's \"big\" speaker"])
        XCTAssertTrue(script.contains("{AirPlay device \"Mia's \\\"big\\\" speaker\"}"))
        XCTAssertTrue(MusicOutputs.selectAirPlayScript([]).contains("whose kind is computer"))
    }

    // MARK: Spotify

    func testSpotifyDevicesSkipRestrictedOnes() throws {
        let json = """
        {"devices": [
          {"id": "a1", "is_active": true, "is_restricted": false, "name": "Office MacBook", "type": "Computer", "volume_percent": 70},
          {"id": "b2", "is_active": false, "is_restricted": false, "name": "Kitchen", "type": "Speaker", "volume_percent": 30},
          {"id": "c3", "is_active": false, "is_restricted": true, "name": "Car", "type": "Automobile"},
          {"id": "d4", "is_active": false, "name": "Pixel", "type": "Smartphone"}
        ]}
        """
        let devices = MusicOutputs.spotifyDevices(from: Data(json.utf8))
        XCTAssertEqual(devices.map(\.name), ["Office MacBook", "Kitchen", "Pixel"])
        XCTAssertEqual(devices.map(\.kind), [.computer, .speaker, .phone])
        XCTAssertEqual(devices.first?.volume, 70)
        XCTAssertEqual(devices.first?.route, .spotify("a1"))
        XCTAssertTrue(MusicOutputs.spotifyDevices(from: Data("{}".utf8)).isEmpty)
    }

    func testSpotifyThisMacIsFoundByNameOrAsTheOnlyComputer() {
        let devices = [
            MusicOutput(route: .spotify("a"), name: "Office iMac", kind: .computer, active: false),
            MusicOutput(route: .spotify("b"), name: "MacBook", kind: .computer, active: false),
            MusicOutput(route: .spotify("c"), name: "Kitchen", kind: .speaker, active: true),
        ]
        XCTAssertEqual(MusicOutputs.spotifyThisMac(devices, macName: "macbook")?.id, "spotify:b")
        XCTAssertNil(MusicOutputs.spotifyThisMac(devices, macName: "Somebody's Mac"))
        XCTAssertEqual(MusicOutputs.spotifyThisMac(Array(devices.dropFirst()), macName: "Somebody's Mac")?.id, "spotify:b")
        XCTAssertEqual(MusicOutputs.elsewhere(devices, macName: "MacBook").map(\.name), ["Office iMac", "Kitchen"])
    }

    func testSpotifyTransferKeepsPlaying() {
        let body = MusicOutputs.spotifyTransferBody(deviceID: "b2")
        XCTAssertEqual(body["device_ids"] as? [String], ["b2"])
        XCTAssertEqual(body["play"] as? Bool, true)
    }

    // MARK: Together

    func testADeviceElsewhereWinsOverTheMacsOwnOutput() {
        let mac = [MusicOutput(route: .mac(1), name: "MacBook Pro Speakers", kind: .speaker, active: true)]
        let kitchen = MusicOutput(route: .spotify("b"), name: "Kitchen", kind: .speaker, active: true)
        XCTAssertEqual(MusicOutputs.current(mac: mac, elsewhere: [kitchen])?.name, "Kitchen")
        XCTAssertEqual(MusicOutputs.current(mac: mac, elsewhere: [])?.name, "MacBook Pro Speakers")
        XCTAssertFalse(kitchen.isOnThisMac)
        XCTAssertTrue(mac[0].isOnThisMac)
    }
}
