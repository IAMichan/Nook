import XCTest

/// The brain's own web requests must never reach the Mac itself or the local network.
final class NetworkGuardTests: XCTestCase {
    private func v4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }

    func testPrivateIPv4Ranges() {
        for address in [v4(127, 0, 0, 1), v4(10, 1, 2, 3), v4(172, 16, 0, 1), v4(172, 31, 255, 255), v4(192, 168, 1, 20),
                        v4(169, 254, 169, 254), v4(100, 64, 0, 1), v4(0, 0, 0, 0), v4(224, 0, 0, 1), v4(255, 255, 255, 255)] {
            XCTAssertTrue(NetworkGuard.isPrivateIPv4(address), String(address, radix: 16))
        }
        for address in [v4(8, 8, 8, 8), v4(172, 32, 0, 1), v4(192, 169, 0, 1), v4(100, 128, 0, 1), v4(1, 1, 1, 1)] {
            XCTAssertFalse(NetworkGuard.isPrivateIPv4(address), String(address, radix: 16))
        }
    }

    func testPrivateIPv6Ranges() {
        var loopback = [UInt8](repeating: 0, count: 16); loopback[15] = 1
        var uniqueLocal = [UInt8](repeating: 0, count: 16); uniqueLocal[0] = 0xFD
        var linkLocal = [UInt8](repeating: 0, count: 16); linkLocal[0] = 0xFE; linkLocal[1] = 0x80
        var mapped = [UInt8](repeating: 0, count: 16); mapped[10] = 0xFF; mapped[11] = 0xFF; mapped[12] = 192; mapped[13] = 168; mapped[14] = 0; mapped[15] = 1
        var publicAddress = [UInt8](repeating: 0, count: 16); publicAddress[0] = 0x26; publicAddress[1] = 0x06
        XCTAssertTrue(NetworkGuard.isPrivateIPv6(loopback))
        XCTAssertTrue(NetworkGuard.isPrivateIPv6(uniqueLocal))
        XCTAssertTrue(NetworkGuard.isPrivateIPv6(linkLocal))
        XCTAssertTrue(NetworkGuard.isPrivateIPv6(mapped))
        XCTAssertFalse(NetworkGuard.isPrivateIPv6(publicAddress))
    }

    func testNamesAndNumericHostsThatResolveLocally() {
        XCTAssertTrue(NetworkGuard.isPrivateName("localhost"))
        XCTAssertTrue(NetworkGuard.isPrivateName("printer.local"))
        XCTAssertTrue(NetworkGuard.isPrivateName("[::1]") || NetworkGuard.resolvesToPrivate("[::1]"))
        // Numeric spellings of 127.0.0.1 that a name check alone would miss.
        XCTAssertTrue(NetworkGuard.resolvesToPrivate("127.0.0.1"))
        XCTAssertTrue(NetworkGuard.resolvesToPrivate("2130706433"))
        XCTAssertTrue(NetworkGuard.resolvesToPrivate("0x7f000001"))
        XCTAssertTrue(NetworkGuard.resolvesToPrivate("localhost"))
    }

    func testCheckRejectsBadURLs() {
        XCTAssertThrowsError(try NetworkGuard.check(URL(string: "file:///etc/passwd")!))
        XCTAssertThrowsError(try NetworkGuard.check(URL(string: "http://127.0.0.1:8080/admin")!))
        XCTAssertThrowsError(try NetworkGuard.check(URL(string: "https://user:pw@example.com/")!))
    }
}
