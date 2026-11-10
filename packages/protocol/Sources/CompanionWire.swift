import Foundation
#if canImport(Compression)
import Compression
#endif

// What travels inside a sealed companion message (docs/COMPANION.md, "Compression"). Plain JSON, as always; or, when both
// sides agreed to it, the same JSON compressed before it is sealed:
//
//   "\0NZ" + "d" + <4-byte big-endian length of the JSON> + <raw DEFLATE (RFC 1951) of the JSON>
//
// JSON never starts with a zero byte, so a reader tells the two apart by the first byte, and a message that is not
// compressed reads as before. Compression happens before sealing: sealed bytes look random and do not compress.
//
// Who compresses what:
// - The phone sets `CompanionRequest.compression` when it can open compressed answers. The Mac compresses an answer (and
//   what it sends by itself over a subscribed connection) only for such a phone, and only when it is larger than
//   `threshold` and gets smaller. An older phone never sets it and always gets plain JSON.
// - The Mac lists `CompanionFeature.compression` when it opens compressed requests. A phone compresses a request only
//   for such a Mac. An older Mac never sees one.
//
// The algorithm byte leaves room for another one later; a reader refuses one it does not know. Apple's Compression
// framework writes raw DEFLATE for `COMPRESSION_ZLIB`, which every platform can read (zlib with negative window bits).
// Where the framework is missing (Linux), nothing is compressed and a compressed message cannot be read.

enum CompanionWire {
    /// The first bytes of a compressed message.
    static let magic = Data([0x00, 0x4E, 0x5A])
    /// Raw DEFLATE.
    static let deflate: UInt8 = 0x64
    /// Smaller than this, a message goes as it is: compressing it saves next to nothing.
    static let threshold = 2 * 1024
    /// The largest message a compressed one may open to, so a few bytes cannot unpack into gigabytes.
    static let maxExpanded = 8 * 1024 * 1024

    enum Failure: Error { case malformed, unsupported, tooLarge }

    /// Whether this build can compress at all.
    static var available: Bool {
        #if canImport(Compression)
        return true
        #else
        return false
        #endif
    }

    /// `json` as it goes into the seal: compressed when `compress` is set, it is at least `threshold` long and it gets
    /// smaller; else unchanged.
    static func pack(_ json: Data, compress: Bool) -> Data {
        guard compress, json.count >= threshold, json.count <= maxExpanded, let packed = deflated(json),
              packed.count + 8 < json.count else { return json }
        let n = json.count
        return magic + Data([deflate, UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]) + packed
    }

    /// The JSON of an opened message, compressed or not.
    static func unpack(_ payload: Data) throws -> Data {
        guard isCompressed(payload) else { return payload }
        let bytes = [UInt8](payload.prefix(8))
        guard bytes.count == 8 else { throw Failure.malformed }
        guard bytes[3] == deflate else { throw Failure.unsupported }
        let length = bytes[4...7].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maxExpanded else { throw Failure.tooLarge }
        guard let json = inflated(payload.dropFirst(8), length: length) else { throw Failure.malformed }
        return json
    }

    static func isCompressed(_ payload: Data) -> Bool { payload.starts(with: magic) }

    /// A value as it goes into the seal.
    static func encode<Value: Encodable>(_ value: Value, compress: Bool) throws -> Data {
        pack(try JSONEncoder().encode(value), compress: compress)
    }

    /// A value from an opened message, compressed or not.
    static func decode<Value: Decodable>(_ type: Value.Type, from payload: Data) throws -> Value {
        try JSONDecoder().decode(type, from: unpack(payload))
    }

    // MARK: DEFLATE

    private static func deflated(_ data: Data) -> Data? {
        #if canImport(Compression)
        // Raw DEFLATE never grows by more than a few bytes per 16 KB block; anything larger is no use anyway.
        let capacity = data.count + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
        #else
        return nil
        #endif
    }

    /// Exactly `length` bytes, or nil: a message that opens to more or less than it said is refused.
    private static func inflated(_ data: Data, length: Int) -> Data? {
        #if canImport(Compression)
        guard !data.isEmpty else { return nil }
        // One byte more than promised tells a message that says too little from one that says the truth.
        let capacity = length + 1
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == length else { return nil }
        out.count = written
        return out
        #else
        return nil
        #endif
    }
}
