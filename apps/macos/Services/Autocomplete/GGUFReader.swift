import Foundation

/// What a GGUF model file says about itself (the header and the first metadata entries).
struct GGUFInfo: Equatable {
    var version: UInt32
    /// `general.architecture`, e.g. "llama", "qwen3", "gemma3".
    var architecture: String?
    /// `general.name`, the model's own name.
    var name: String?
    /// `<architecture>.context_length`: how many tokens the model was trained to read at once.
    var contextLength: Int?
}

/// Reads the header of a GGUF file (the format llama.cpp loads) without loading the model, to recognise a file and show
/// what it is. Foundation only; every read is bounds-checked, so a damaged or foreign file gives nil instead of a crash.
enum GGUFReader {
    /// The metadata sits at the start of the file; the weights come after it.
    static let headBytes = 4 * 1024 * 1024

    static func read(_ url: URL) -> GGUFInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes) else { return nil }
        return parse(head)
    }

    static func parse(_ data: Data) -> GGUFInfo? {
        var cursor = Cursor(bytes: Array(data))
        guard cursor.take(4) == Array("GGUF".utf8),
              let version = cursor.u32(), (1...3).contains(version),
              cursor.u64() != nil,                    // tensor count
              let entries = cursor.u64() else { return nil }
        var info = GGUFInfo(version: version)
        for _ in 0..<min(entries, 4_096) {
            guard let key = cursor.string(), let type = cursor.u32() else { break }
            if type == 8, let value = cursor.string() {
                if key == "general.architecture" { info.architecture = value }
                if key == "general.name" { info.name = value }
            } else if (type == 4 || type == 5 || type == 10 || type == 11), key.hasSuffix(".context_length") {
                guard let value = cursor.integer(type: type) else { break }
                if key == (info.architecture ?? "") + ".context_length" { info.contextLength = Int(clamping: value) }
            } else if !cursor.skip(type: type) {
                break
            }
            if info.architecture != nil, info.name != nil, info.contextLength != nil { break }
        }
        return info
    }

    /// A little-endian reader over a byte array that never reads past the end.
    private struct Cursor {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= bytes.count - position else { return nil }
            defer { position += count }
            return Array(bytes[position..<position + count])
        }

        mutating func u32() -> UInt32? {
            guard let b = take(4) else { return nil }
            return b.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }

        mutating func u64() -> UInt64? {
            guard let b = take(8) else { return nil }
            return b.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }

        mutating func string() -> String? {
            guard let count = u64(), count <= UInt64(bytes.count), let b = take(Int(count)) else { return nil }
            return String(decoding: b, as: UTF8.self)
        }

        mutating func integer(type: UInt32) -> UInt64? {
            switch type {
            case 4, 5: return u32().map { UInt64($0) }
            default: return u64()
            }
        }

        /// Steps over a value of this type; false when the value runs past what was read.
        mutating func skip(type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7: return take(1) != nil
            case 2, 3: return take(2) != nil
            case 4, 5, 6: return take(4) != nil
            case 10, 11, 12: return take(8) != nil
            case 8: return string() != nil
            case 9:
                guard let element = u32(), let count = u64() else { return false }
                let fixed: [UInt32: Int] = [0: 1, 1: 1, 7: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 10: 8, 11: 8, 12: 8]
                if let size = fixed[element] {
                    let (total, overflow) = count.multipliedReportingOverflow(by: UInt64(size))
                    return !overflow && total <= UInt64(bytes.count) && take(Int(total)) != nil
                }
                guard count <= UInt64(bytes.count) else { return false }
                var done: UInt64 = 0
                while done < count {
                    if !skip(type: element) { return false }
                    done += 1
                }
                return true
            default: return false
            }
        }
    }
}
