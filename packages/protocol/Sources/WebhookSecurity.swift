import Foundation

// Webhook verification without CryptoKit, which does not exist on Linux where the core
// tests run. The types are called `PureSHA256` / `PureHMAC` because files that `import CryptoKit` use `SHA256` and
// `HMAC<…>` from it: a module-level type with those names would shadow CryptoKit's inside the app target.

/// SHA-256 as in FIPS 180-4.
struct PureSHA256: Sendable {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static let blockSize = 64

    static func hash(_ data: Data) -> Data {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out = Data()
        for word in h { for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8((word >> UInt32(shift)) & 0xff)) } }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

/// HMAC (RFC 2104) over SHA-256.
enum PureHMAC {
    static func sha256(key: Data, message: Data) -> Data {
        var k = key.count > PureSHA256.blockSize ? PureSHA256.hash(key) : key
        k.append(Data(repeating: 0, count: PureSHA256.blockSize - k.count))
        let inner = Data(k.map { $0 ^ 0x36 }) + message
        let outer = Data(k.map { $0 ^ 0x5c }) + PureSHA256.hash(inner)
        return PureSHA256.hash(outer)
    }
}

enum WebhookHex {
    static func encode(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(data.count * 2)
        for byte in data { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 0x0f)]) }
        return out
    }

    /// Nil for an odd length or a non-hex character; case does not matter.
    static func decode(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out = Data(capacity: bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }
}

enum WebhookVerifier {
    /// Compares without stopping at the first difference, so timing does not reveal how much of a signature was right.
    /// A length difference is folded into the result instead of returning early.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        let x = [UInt8](a), y = [UInt8](b)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count) | UInt8(truncatingIfNeeded: (x.count ^ y.count) >> 8)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    /// `signatureHeader` is `sha256=<hex>` or bare hex (GitHub style and plain), any case, surrounding spaces ignored.
    /// No secret or no header never verifies: an unsigned hook is a separate, explicit choice of the caller.
    static func verify(secret: String, body: Data, signatureHeader: String?) -> Bool {
        guard !secret.isEmpty, var value = signatureHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
        if value.lowercased().hasPrefix("sha256=") { value = String(value.dropFirst("sha256=".count)) }
        guard let received = WebhookHex.decode(value) else { return false }
        let expected = PureHMAC.sha256(key: Data(secret.utf8), message: body)
        return constantTimeEqual(received, expected)
    }

    /// For tests and for showing the sender what to send.
    static func signature(secret: String, body: Data) -> String {
        "sha256=" + WebhookHex.encode(PureHMAC.sha256(key: Data(secret.utf8), message: body))
    }
}

/// Delivery ids seen recently, so a replayed request is refused.
struct DeliveryLog: Codable, Equatable, Sendable {
    static let defaultRetention = 50

    private(set) var ids: [String] = []
    let capacity: Int

    init(capacity: Int = DeliveryLog.defaultRetention) { self.capacity = max(1, capacity) }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// True when `id` is new; false for a replay. The oldest id is forgotten once the log is full.
    mutating func record(_ id: String) -> Bool {
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > capacity { ids.removeFirst(ids.count - capacity) }
        return true
    }
}

/// At most `limit` accepted deliveries per window (default: 60 per minute per task, also behind the relay because the
/// tunnel hostname is public). The clock is passed in.
struct RateWindow: Equatable, Sendable {
    static let defaultLimit = 60
    static let defaultWindow: TimeInterval = 60

    enum Decision: Equatable, Sendable {
        case accepted
        /// `first`: the first refusal in this window, the only one worth logging.
        case limited(first: Bool)
    }

    let limit: Int
    let window: TimeInterval
    private var accepted: [Date] = []
    private var rejectedLogged = false

    init(limit: Int = RateWindow.defaultLimit, window: TimeInterval = RateWindow.defaultWindow) {
        self.limit = max(1, limit)
        self.window = window
    }

    mutating func admit(now: Date) -> Decision {
        accepted.removeAll { now.timeIntervalSince($0) >= window }
        if accepted.count < limit {
            accepted.append(now)
            rejectedLogged = false
            return .accepted
        }
        let first = !rejectedLogged
        rejectedLogged = true
        return .limited(first: first)
    }
}
