import XCTest

final class RemoteHostDiscoveryTests: XCTestCase {
    func testConfigAliasesWithoutPatterns() {
        let config = """
        Host *
          ServerAliveInterval 30
        Host buildbox bb
          HostName 10.0.0.4
          User ubuntu
        # a comment
        Host=pi
          HostName=raspberrypi.local
        Host *.internal !secret
        Match host foo
          User nobody
        """
        let found = RemoteHostDiscovery.sshConfig(config)
        XCTAssertEqual(found.map(\.host), ["buildbox", "bb", "pi"])
        XCTAssertEqual(found.first?.detail, "ubuntu@10.0.0.4")
        XCTAssertEqual(found.last?.detail, "raspberrypi.local")
        XCTAssertTrue(found.allSatisfy { $0.source == .sshConfig && $0.port == nil })
    }

    func testKnownHostsSkipHashedEntriesAndForges() {
        let known = """
        github.com ssh-ed25519 AAAA
        buildbox.local,10.0.0.4 ssh-ed25519 AAAA
        [devbox.local]:2222 ssh-rsa AAAA
        [old.local]:22 ssh-rsa AAAA
        |1|abc=|def= ssh-ed25519 AAAA
        @cert-authority *.corp ssh-rsa AAAA
        @revoked bad.local ssh-rsa AAAA
        """
        let found = RemoteHostDiscovery.knownHosts(known)
        XCTAssertEqual(found.map(\.host), ["buildbox.local", "10.0.0.4", "devbox.local", "old.local", "bad.local"])
        XCTAssertEqual(found.first { $0.host == "devbox.local" }?.port, 2222)
        XCTAssertNil(found.first { $0.host == "old.local" }?.port)
    }

    func testTailnetPeersByMagicDNSName() throws {
        let json = """
        {"Self": {"HostName": "my-mac", "DNSName": "my-mac.tail1.ts.net.", "Online": true},
         "Peer": {
           "a": {"HostName": "buildbox", "DNSName": "buildbox.tail1.ts.net.", "Online": true, "OS": "linux", "TailscaleIPs": ["100.64.0.2"]},
           "b": {"HostName": "phone", "DNSName": "phone.tail1.ts.net.", "Online": false, "OS": "iOS"},
           "c": {"HostName": "", "DNSName": "", "Online": true, "TailscaleIPs": ["100.64.0.9"]}
         }}
        """
        let found = RemoteHostDiscovery.tailscale(Data(json.utf8))
        XCTAssertEqual(found.map(\.host), ["100.64.0.9", "buildbox.tail1.ts.net"])
        XCTAssertEqual(found.last?.name, "buildbox")
        XCTAssertEqual(found.last?.detail, "linux")
        XCTAssertEqual(RemoteHostDiscovery.tailscale(Data("not json".utf8)), [])
    }

    func testMergeDropsDuplicatesAndMachinesYouHave() {
        let tail = [RemoteHostDiscovery.Suggestion(name: "buildbox", host: "buildbox.local", port: nil, source: .tailscale, detail: nil)]
        let config = [RemoteHostDiscovery.Suggestion(name: "pi", host: "pi", port: nil, source: .sshConfig, detail: nil)]
        let known = [RemoteHostDiscovery.Suggestion(name: "x", host: "BUILDBOX.local", port: nil, source: .knownHosts, detail: nil),
                     RemoteHostDiscovery.Suggestion(name: "y", host: "pi", port: 2222, source: .knownHosts, detail: nil)]
        let merged = RemoteHostDiscovery.merge(tailscale: tail, sshConfig: config, knownHosts: known,
                                               existing: [RemoteMachine(name: "pi", host: "me@pi")])
        XCTAssertEqual(merged.map(\.id), ["buildbox.local:0", "pi:2222"])
    }
}
