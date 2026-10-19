import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Keeps the brain's own web requests away from the user's Mac and local network.
///
/// A host name is not enough to judge: `printer.example.com` can resolve to 192.168.1.20 and `2130706433` is 127.0.0.1.
/// So the host is resolved and every address is checked, and redirects are followed by hand so each hop is checked too.
enum NetworkGuard {
    /// Hosts that are private by name alone.
    static func isPrivateName(_ host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if lower.isEmpty || lower == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home", ".corp", ".intranet"] where lower.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// Whether an IPv4 address (in host byte order) is loopback, private, link-local, shared or otherwise not public.
    static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let a = address >> 24, b = (address >> 16) & 0xFF
        switch a {
        case 0, 10, 127: return true
        case 100: return (64...127).contains(b)          // carrier-grade NAT
        case 169: return b == 254                        // link-local
        case 172: return (16...31).contains(b)
        case 192: return b == 168 || (b == 0 && ((address >> 8) & 0xFF) == 0)
        case 198: return b == 18 || b == 19              // benchmarking
        default: return a >= 224                         // multicast and reserved
        }
    }

    /// Whether an IPv6 address is loopback, unspecified, unique-local, link-local, or an IPv4-mapped private address.
    static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) { return true }                 // :: and ::1
        if bytes[0] & 0xFE == 0xFC { return true }                                // fc00::/7
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }            // fe80::/10
        if bytes[0] == 0xFF { return true }                                       // multicast
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            let v4 = UInt32(bytes[12]) << 24 | UInt32(bytes[13]) << 16 | UInt32(bytes[14]) << 8 | UInt32(bytes[15])
            return isPrivateIPv4(v4)                                              // ::ffff:a.b.c.d
        }
        return false
    }

    /// Resolves the host and returns true if any address is not public. Unresolvable hosts count as private.
    static func resolvesToPrivate(_ host: String) -> Bool {
        if isPrivateName(host) { return true }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else { return true }
        defer { freeaddrinfo(first) }
        var found = false
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer {
            defer { pointer = info.pointee.ai_next }
            guard let address = info.pointee.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                found = true
                if isPrivateIPv4(UInt32(bigEndian: v4)) { return true }
            case AF_INET6:
                var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: &raw) { Array($0) }
                found = true
                if isPrivateIPv6(bytes) { return true }
            default:
                continue
            }
        }
        return !found
    }

    /// Checks scheme and host of a URL the brain wants to fetch.
    static func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else {
            throw NookError("Invalid web address.")
        }
        guard url.user == nil, url.password == nil else { throw NookError("Addresses with a login in them are not opened.") }
        if resolvesToPrivate(host) {
            throw NookError("Nook does not open addresses on your Mac or local network.")
        }
    }

    /// Session that never follows redirects by itself; `fetch` follows them and checks every hop.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            "Accept-Language": "nl-NL,nl;q=0.9,en;q=0.8"
        ]
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Fetches a public URL, following at most five redirects, each one checked again.
    static func fetch(_ start: URL) async throws -> (Data, HTTPURLResponse) {
        var url = start
        for _ in 0..<6 {
            let target = url
            try await Task.detached(priority: .utility) { try check(target) }.value
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw NookError("No answer from that page.") }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
               let next = URL(string: location, relativeTo: url)?.absoluteURL {
                url = next
                continue
            }
            return (data, http)
        }
        throw NookError("That page redirects too often.")
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
