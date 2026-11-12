import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Approving a local dev server's own HTTPS certificate in Nook's browser (`vite --https`, mkcert, a self-signed
/// certificate).
///
/// Only for an address that is local by its name or number alone (`isLocal`); a public site with a certificate macOS does
/// not trust keeps WebKit's error and can never be approved. An approval belongs to the host, the port and the
/// certificate's SHA-256 fingerprint: another port is another server, and a renewed certificate asks again. "Trust for
/// this session" lasts until Nook quits; "Always trust" is kept in UserDefaults (a fingerprint is no secret) and Settings ›
/// Editor & browser forgets it.
///
/// Only you can approve: the question is a native bar above the page (`BrowserView`), which an agent driving the page
/// with the browser tools cannot reach, since those act inside the page. There is no tool that trusts a certificate.
enum LocalCertificateTrust {
    /// Whether a host is on this Mac or the local network by name or address alone, without asking DNS (an answer an
    /// attacker can choose, as in DNS rebinding):
    /// - `localhost` and `*.localhost` (RFC 6761), `*.local` (Bonjour, a Mac or device on the network);
    /// - loopback `127.0.0.0/8`, `::1`, and `0.0.0.0` / `::` (which reach this Mac);
    /// - private IPv4 `10/8`, `172.16/12`, `192.168/16`, link-local `169.254/16`;
    /// - IPv6 unique-local `fc00::/7`, link-local `fe80::/10`, and IPv4-mapped forms of the above.
    ///
    /// Not local: any other name (`dev.example.com`, `myapp.test`, `*.internal`), even when it resolves to `127.0.0.1`,
    /// and carrier-grade NAT `100.64/10` (also used by ISPs and VPNs such as Tailscale).
    static func isLocal(_ host: String) -> Bool {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        // A zone ("fe80::1%en0") says which interface, not where.
        if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty else { return false }
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        if let v4 = ipv4(name) { return isLocalIPv4(v4) }
        if let v6 = ipv6(name) { return isLocalIPv6(v6) }
        // A name: only Bonjour's own domain is local by name.
        return name.hasSuffix(".local") && name.count > ".local".count
    }

    static func isLocalIPv4(_ address: UInt32) -> Bool {
        let a = address >> 24, b = (address >> 16) & 0xFF
        switch a {
        case 0: return address == 0                  // 0.0.0.0 reaches this Mac
        case 10, 127: return true
        case 169: return b == 254
        case 172: return (16...31).contains(b)
        case 192: return b == 168
        default: return false
        }
    }

    static func isLocalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) { return bytes[15] <= 1 }        // :: and ::1
        if bytes[0] & 0xFE == 0xFC { return true }                                // fc00::/7
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }            // fe80::/10
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            let v4 = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return isLocalIPv4(v4)                                                // ::ffff:a.b.c.d
        }
        return false
    }

    /// Dotted IPv4 in host byte order; nil for anything else (`inet_pton` takes only the four-part decimal form, so
    /// `2130706433` or `0x7f.1` are names here, and names are not local).
    static func ipv4(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// The port an https address connects to.
    static func port(of url: URL) -> Int {
        url.port ?? 443
    }
}

/// One certificate you approved: for this host and port, this certificate.
struct CertificateApproval: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    /// SHA-256 of the certificate's DER bytes, lowercase hex.
    var fingerprint: String

    init(host: String, port: Int, fingerprint: String) {
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
        self.fingerprint = fingerprint.lowercased()
    }
}

/// The certificates approved so far: for this session in memory, "always" in UserDefaults. Refuses any host that is not
/// local (`LocalCertificateTrust.isLocal`), whatever asks.
final class CertificateTrustStore: @unchecked Sendable {
    static let shared = CertificateTrustStore()
    static let defaultsKey = "nook.browser.trustedCertificates"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private var session: Set<CertificateApproval> = []

    init(defaults: UserDefaults = .standard, key: String = CertificateTrustStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// Whether this certificate was approved for this host and port, this session or for good. Never for a public host,
    /// also when a stored entry says so (an older build, an edited preferences file).
    func isTrusted(_ approval: CertificateApproval) -> Bool {
        guard LocalCertificateTrust.isLocal(approval.host) else { return false }
        lock.lock()
        defer { lock.unlock() }
        return session.contains(approval) || stored().contains(approval)
    }

    /// Approves a certificate; `always` keeps it after Nook quits. False, and nothing kept, for a host that is not local.
    @discardableResult
    func trust(_ approval: CertificateApproval, always: Bool) -> Bool {
        guard LocalCertificateTrust.isLocal(approval.host), !approval.fingerprint.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        session.insert(approval)
        if always {
            var kept = stored()
            // A renewed certificate for the same server replaces the one before it, so the list does not grow forever.
            kept.removeAll { $0.host == approval.host && $0.port == approval.port }
            kept.append(approval)
            save(kept)
        }
        return true
    }

    /// The certificates you chose to always trust.
    var remembered: [CertificateApproval] {
        lock.lock()
        defer { lock.unlock() }
        return stored()
    }

    /// Forgets every approval, this session's too (Settings › Editor & browser).
    func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        session.removeAll()
        defaults.removeObject(forKey: key)
    }

    private func stored() -> [CertificateApproval] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode(LossyArray<CertificateApproval>.self, from: data) else { return [] }
        return list.elements.filter { LocalCertificateTrust.isLocal($0.host) }
    }

    private func save(_ list: [CertificateApproval]) {
        defaults.setEncoded(list, forKey: key)
    }
}
