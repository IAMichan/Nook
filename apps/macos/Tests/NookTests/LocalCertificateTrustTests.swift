import XCTest

/// Which hosts may have their own certificate approved in Nook's browser, and how approvals are kept: per host, port and
/// fingerprint, for the session or for good, and never for a public host.
final class LocalCertificateTrustTests: XCTestCase {
    private let suite = "nook.tests.certificateTrust"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Hosts

    func testLocalHosts() {
        for host in ["localhost", "LOCALHOST", "localhost.", "app.localhost", "api.my-app.localhost",
                     "127.0.0.1", "127.1.2.3", "0.0.0.0", "::1", "[::1]", "::", "[::ffff:127.0.0.1]",
                     "10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.10.1",
                     "fd12:3456:789a::1", "fc00::1", "fe80::1", "fe80::1%en0", "[fe80::1%25en0]",
                     "my-mac.local", "printer.local."] {
            XCTAssertTrue(LocalCertificateTrust.isLocal(host), host)
        }
    }

    func testPublicHostsAreNeverLocal() {
        for host in ["example.com", "localhost.example.com", "evil-localhost", "mylocalhost", "local", ".local",
                     "dev.example.local.com", "myapp.test", "service.internal", "router.lan",
                     "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "11.0.0.1", "100.64.0.1", "1.1.1.1",
                     "2130706433", "0x7f000001", "127.1", "2001:4860:4860::8888", "::ffff:8.8.8.8", "", " "] {
            XCTAssertFalse(LocalCertificateTrust.isLocal(host), host)
        }
    }

    func testPortDefaultsTo443() {
        XCTAssertEqual(LocalCertificateTrust.port(of: URL(string: "https://localhost/")!), 443)
        XCTAssertEqual(LocalCertificateTrust.port(of: URL(string: "https://localhost:5173/")!), 5173)
    }

    // MARK: Approvals

    private let vite = CertificateApproval(host: "localhost", port: 5173, fingerprint: "AB12")

    func testSessionTrustCoversThisHostPortAndCertificateOnly() {
        let store = CertificateTrustStore(defaults: defaults)
        XCTAssertFalse(store.isTrusted(vite))
        XCTAssertTrue(store.trust(vite, always: false))
        XCTAssertTrue(store.isTrusted(vite))
        XCTAssertTrue(store.isTrusted(CertificateApproval(host: "LocalHost", port: 5173, fingerprint: "ab12")))
        // Another port is another server; a renewed certificate asks again; another host too.
        XCTAssertFalse(store.isTrusted(CertificateApproval(host: "localhost", port: 5174, fingerprint: "ab12")))
        XCTAssertFalse(store.isTrusted(CertificateApproval(host: "localhost", port: 5173, fingerprint: "cd34")))
        XCTAssertFalse(store.isTrusted(CertificateApproval(host: "127.0.0.1", port: 5173, fingerprint: "ab12")))
        // Only in memory: a new launch does not know it.
        XCTAssertTrue(store.remembered.isEmpty)
        XCTAssertFalse(CertificateTrustStore(defaults: defaults).isTrusted(vite))
    }

    func testAlwaysTrustOutlivesTheSessionAndRenewalReplacesIt() {
        let store = CertificateTrustStore(defaults: defaults)
        XCTAssertTrue(store.trust(vite, always: true))
        let relaunched = CertificateTrustStore(defaults: defaults)
        XCTAssertTrue(relaunched.isTrusted(vite))
        XCTAssertEqual(relaunched.remembered, [vite])

        let renewed = CertificateApproval(host: "localhost", port: 5173, fingerprint: "ef56")
        relaunched.trust(renewed, always: true)
        XCTAssertEqual(relaunched.remembered, [renewed], "one entry per server")
        let other = CertificateApproval(host: "my-mac.local", port: 8443, fingerprint: "0101")
        relaunched.trust(other, always: true)
        XCTAssertEqual(Set(relaunched.remembered), [renewed, other])

        relaunched.forgetAll()
        XCTAssertTrue(relaunched.remembered.isEmpty)
        XCTAssertFalse(relaunched.isTrusted(renewed))
        XCTAssertFalse(CertificateTrustStore(defaults: defaults).isTrusted(other))
    }

    func testPublicHostsCannotBeTrustedWhateverAsks() throws {
        let store = CertificateTrustStore(defaults: defaults)
        let bank = CertificateApproval(host: "bank.example.com", port: 443, fingerprint: "ab12")
        XCTAssertFalse(store.trust(bank, always: false))
        XCTAssertFalse(store.trust(bank, always: true))
        XCTAssertFalse(store.isTrusted(bank))
        XCTAssertTrue(store.remembered.isEmpty)
        XCTAssertFalse(store.trust(CertificateApproval(host: "localhost", port: 443, fingerprint: ""), always: true))

        // A stored entry for a public host (an edited preferences file) is ignored.
        let planted = try JSONEncoder().encode([bank, vite])
        defaults.set(planted, forKey: CertificateTrustStore.defaultsKey)
        let reread = CertificateTrustStore(defaults: defaults)
        XCTAssertFalse(reread.isTrusted(bank))
        XCTAssertTrue(reread.isTrusted(vite))
        XCTAssertEqual(reread.remembered, [vite])
    }

    func testUnreadableStoredListIsEmptyNotACrash() {
        defaults.set(Data("not json".utf8), forKey: CertificateTrustStore.defaultsKey)
        let store = CertificateTrustStore(defaults: defaults)
        XCTAssertTrue(store.remembered.isEmpty)
        XCTAssertFalse(store.isTrusted(vite))
    }
}
