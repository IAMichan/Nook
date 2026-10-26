import XCTest

/// Several Macs on one phone (`CompanionPairings`).
final class CompanionPairingsTests: XCTestCase {
    private func link(_ byte: UInt8, name: String = "Studio", host: String = "studio.local") -> PairingLink {
        PairingLink(host: host, port: 5000, key: Data(repeating: byte, count: PairingLink.keyLength), macName: name)
    }

    func testAddingMakesTheMacActive() {
        var pairings = CompanionPairings()
        XCTAssertTrue(pairings.isEmpty)
        pairings.add(link(1))
        pairings.add(link(2, name: "Laptop", host: "laptop.local"))
        XCTAssertEqual(pairings.macs.count, 2)
        XCTAssertEqual(pairings.active?.name, "Laptop")
        XCTAssertEqual(pairings.others.map(\.name), ["Studio"])
        XCTAssertTrue(pairings.select(pairings.macs[0].id))
        XCTAssertEqual(pairings.active?.name, "Studio")
        XCTAssertFalse(pairings.select("nope"))
    }

    func testPairingTheSameMacAgainReplacesIt() {
        var pairings = CompanionPairings()
        pairings.add(link(1))
        pairings.add(link(1))
        XCTAssertEqual(pairings.macs.count, 1, "the same key")
        pairings.add(link(3))
        XCTAssertEqual(pairings.macs.count, 1, "a new key for the same Mac replaces the dead pairing")
        XCTAssertEqual(pairings.active?.id, PairedDevice.identifier(forKey: link(3).key))
    }

    func testRemovingTheActiveMacPicksAnother() {
        var pairings = CompanionPairings()
        pairings.add(link(1))
        pairings.add(link(2, name: "Laptop", host: "laptop.local"))
        let laptop = pairings.active!.id
        pairings.remove(laptop)
        XCTAssertEqual(pairings.active?.name, "Studio")
        pairings.remove(pairings.active!.id)
        XCTAssertNil(pairings.active)
    }

    func testTheListIsBounded() {
        var pairings = CompanionPairings()
        for i in 0..<CompanionPairings.maxMacs {
            XCTAssertTrue(pairings.add(link(UInt8(i + 1), name: "Mac \(i)", host: "mac\(i).local")))
        }
        XCTAssertFalse(pairings.add(link(99, name: "One more", host: "more.local")))
    }

    func testMigratingTheSinglePairingKeepsItsRoutesAndNames() throws {
        let old = link(1)
        let routes = [CompanionRoute(host: "studio.local", port: 5000), CompanionRoute(host: "100.100.1.1", port: 5000, learned: true, tailnet: true)]
        let pairings = CompanionPairings.migrate(legacy: old, routes: routes)
        XCTAssertEqual(pairings.macs.count, 1)
        XCTAssertEqual(pairings.active?.routes, routes)
        XCTAssertEqual(pairings.active?.link, old)
        let id = try XCTUnwrap(pairings.active?.id)
        XCTAssertEqual(pairings.legacyID, id)
        XCTAssertEqual(CompanionPairings.storageName("companion-outbox.json", mac: id, legacyID: pairings.legacyID), "companion-outbox.json")
        XCTAssertEqual(CompanionPairings.storageName("companion-outbox.json", mac: "abc", legacyID: id), "companion-outbox-abc.json")
        XCTAssertEqual(CompanionPairings.storageName("companion.features", mac: "abc", legacyID: nil), "companion.features.abc")
        XCTAssertTrue(CompanionPairings.migrate(legacy: nil, routes: nil).isEmpty)
    }

    func testRoutesAndNamesFollowPerMac() throws {
        var pairings = CompanionPairings()
        pairings.add(link(1))
        pairings.add(link(2, name: "Laptop", host: "laptop.local"))
        let studio = pairings.macs[0].id
        pairings.setRoutes([CompanionRoute(host: "10.0.0.2", port: 6000)], for: studio)
        pairings.rename(studio, to: "Studio Mac")
        XCTAssertEqual(pairings.macs[0].routes.map(\.host), ["10.0.0.2"])
        XCTAssertEqual(pairings.macs[0].name, "Studio Mac")
        XCTAssertEqual(pairings.macs[1].routes.map(\.host), ["laptop.local"], "the other Mac is untouched")
        let back = try JSONDecoder().decode(CompanionPairings.self, from: JSONEncoder().encode(pairings))
        XCTAssertEqual(back, pairings)
    }
}
