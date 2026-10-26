import Darwin
import Foundation
import SystemConfiguration

/// Where a paired phone can reach this Mac now: its Bonjour name, the IPv4 addresses of its Wi-Fi and Ethernet, and its
/// Tailscale address. The phone keeps them as routes (`CompanionRoutes.merge`), so it follows the Mac to a new Wi-Fi
/// address, and reaches it over Tailscale away from home, without pairing again.
enum CompanionEndpoints {
    static func current(port: UInt16) -> [CompanionEndpoint] {
        var seen: Set<String> = []
        var lan: [CompanionEndpoint] = []
        var tailnet: [CompanionEndpoint] = []
        // The Bonjour name from the system's own configuration: no DNS lookup, so it never stalls.
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            let host = name + ".local"
            if PairingLink.validHost(host), seen.insert(host.lowercased()).inserted {
                lan.append(CompanionEndpoint(host: host, port: port, tailnet: false))
            }
        }
        for (interface, address) in interfaceAddresses() where seen.insert(address).inserted {
            switch CompanionAddress.classify(address) {
            case .lan:
                // A self-assigned address (no DHCP answer) reaches nobody.
                if !address.hasPrefix("169.254.") { lan.append(CompanionEndpoint(host: address, port: port, tailnet: false)) }
            case .vpn:
                // Tailscale's address sits on a utun interface; another VPN in the same range is still worth a try.
                tailnet.append(CompanionEndpoint(host: address, port: port, tailnet: interface.hasPrefix("utun")))
            case .loopback, .tailnet, .internet:
                break
            }
        }
        return lan + tailnet
    }

    /// The IPv4 address of every interface that is up, by interface name ("en0", "utun4").
    private static func interfaceAddresses() -> [(String, String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(String, String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            found.append((String(cString: entry.ifa_name), text))
        }
        return found
    }
}
