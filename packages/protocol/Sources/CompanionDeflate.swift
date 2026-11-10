import Foundation
#if canImport(Compression)
import Compression
#endif

/// Raw DEFLATE (RFC 1951) for large companion messages, before they are sealed (`CompanionSeal`, envelope field `z`).
/// A conversation or a session's changes are JSON that shrinks to a fraction, which matters on mobile data and through
/// the relay. Only a phone that says it reads it (`CompanionRequest.accepts`) gets compressed answers from a Mac that
/// lists `CompanionFeature.deflate`; everything else stays as it was.
///
/// Compression happens before encryption, on JSON the Mac writes itself: the secrets around it (the pairing key, the
/// sealing key) never go into the compressed text, so its length tells nothing about them.
enum CompanionDeflate {
    /// The name in the envelope and in `CompanionRequest.accepts`.
    static let name = "deflate"
    /// Below this a message goes as it is: the saving is too small to be worth the work.
    static let threshold = 2 * 1024
    /// The most a compressed message may grow back to. Far above any answer the Mac sends (`CompanionConstants.maxFrame`
    /// is what goes over the wire); a message that would grow beyond it is refused, so a small frame cannot swell into
    /// a large allocation.
    static let maxInflated = 8 * 1024 * 1024

    /// Whether this build can compress and decompress at all (Apple platforms; not the Linux test build).
    static var isAvailable: Bool {
        #if canImport(Compression)
        return true
        #else
        return false
        #endif
    }

    /// `data` compressed, or nil when it is too small, does not get smaller, or this build cannot compress.
    static func compress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard data.count >= threshold else { return nil }
        // Only worth it when it saves: the output may be at most as long as the input.
        let capacity = data.count
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let from = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(to, capacity, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        output.count = written
        return output
        #else
        return nil
        #endif
    }

    /// `data` decompressed; nil when it is not valid DEFLATE, inflates beyond `maxInflated`, or this build cannot.
    static func decompress(_ data: Data) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        // JSON shrinks to about a fifth: start a little above that, and double while the output fills the whole buffer
        // (then it was cut). One byte over `maxInflated` is the last try, so a full buffer there means too large.
        var capacity = min(max(data.count * 8, 64 * 1024), maxInflated + 1)
        while true {
            var output = Data(count: capacity)
            let size = capacity
            let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
                data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                    guard let to = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let from = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                    return compression_decode_buffer(to, size, from, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            if written < capacity {
                output.count = written
                return output
            }
            guard capacity <= maxInflated else { return nil }
            capacity = min(capacity * 2, maxInflated + 1)
        }
        #else
        return nil
        #endif
    }
}
