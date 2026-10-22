import Foundation

// A voice message as WhatsApp sends one: Opus packets in an Ogg file (RFC 7845). The gateways turn anything else into
// that with ffmpeg, and GOWA refuses a voice note with INTERNAL_SERVER_ERROR when ffmpeg is not installed; an .ogg goes
// as it is. Foundation only: the Opus packets come from Core Audio's encoder (`ChatVoiceOpus`), this puts them in pages.

enum OggOpus {
    /// Samples an Opus decoder drops at the start; 312 is what libopus itself writes at 48 kHz.
    static let defaultPreSkip = 312

    /// The Ogg file for `packets` of mono 48 kHz Opus: the identification header, the comment header, then the audio in
    /// pages of whole packets, each page's granule position the samples decoded by its end.
    static func file(packets: [Data], preSkip: Int = defaultPreSkip, serial: UInt32 = 0x4E6F6F6B) -> Data {
        var pages = Data()
        var sequence: UInt32 = 0
        func add(_ segments: [Data], granule: UInt64, flags: UInt8) {
            pages.append(page(segments, granule: granule, serial: serial, sequence: sequence, flags: flags))
            sequence += 1
        }
        add([head(preSkip: preSkip)], granule: 0, flags: 0x02)
        add([tags()], granule: 0, flags: 0)

        var granule: UInt64 = 0
        var waiting: [Data] = []
        var lacing = 0
        for (index, packet) in packets.enumerated() {
            let needed = packet.count / 255 + 1
            if !waiting.isEmpty, lacing + needed > 255 {
                add(waiting, granule: granule, flags: 0)
                waiting = []
                lacing = 0
            }
            waiting.append(packet)
            lacing += needed
            granule += UInt64(samples(packet))
            if index == packets.count - 1 { add(waiting, granule: granule, flags: 0x04) }
        }
        if packets.isEmpty { add([], granule: 0, flags: 0x04) }
        return pages
    }

    /// `OpusHead`: version 1, one channel, the pre-skip, 48 kHz input, no gain, channel mapping family 0.
    static func head(preSkip: Int) -> Data {
        var data = Data("OpusHead".utf8)
        data.append(1)
        data.append(1)
        data.append(littleEndian: UInt16(clamping: preSkip))
        data.append(littleEndian: UInt32(48_000))
        data.append(littleEndian: UInt16(0))
        data.append(0)
        return data
    }

    /// `OpusTags`: who wrote it and no comments.
    static func tags() -> Data {
        let vendor = Data("Nook".utf8)
        var data = Data("OpusTags".utf8)
        data.append(littleEndian: UInt32(vendor.count))
        data.append(vendor)
        data.append(littleEndian: UInt32(0))
        return data
    }

    /// How many 48 kHz samples one Opus packet decodes to, read from its table-of-contents byte (RFC 6716, 3.1).
    static func samples(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0..<12: frame = [480, 960, 1920, 2880][config % 4]   // SILK: 10, 20, 40, 60 ms
        case 12..<16: frame = [480, 960][config % 2]              // Hybrid: 10, 20 ms
        default: frame = [120, 240, 480, 960][config % 4]         // CELT: 2.5, 5, 10, 20 ms
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 3: frames = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 0
        default: frames = 2
        }
        return frame * frames
    }

    /// One Ogg page holding whole packets: each packet laced as 255-byte segments and a shorter last one.
    static func page(_ packets: [Data], granule: UInt64, serial: UInt32, sequence: UInt32, flags: UInt8) -> Data {
        var lacing = [UInt8]()
        for packet in packets {
            lacing += [UInt8](repeating: 255, count: packet.count / 255)
            lacing.append(UInt8(packet.count % 255))
        }
        var data = Data("OggS".utf8)
        data.append(0)
        data.append(flags)
        data.append(littleEndian: granule)
        data.append(littleEndian: serial)
        data.append(littleEndian: sequence)
        data.append(littleEndian: UInt32(0))   // the checksum, filled in below
        data.append(UInt8(lacing.count))
        data.append(contentsOf: lacing)
        packets.forEach { data.append($0) }
        let sum = crc(data)
        data.replaceSubrange(22..<26, with: withUnsafeBytes(of: sum.littleEndian) { Data($0) })
        return data
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, starting at zero.
    static func crc(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        for byte in data {
            sum = (sum << 8) ^ table[Int(((sum >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return sum
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
