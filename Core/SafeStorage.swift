import Foundation
#if canImport(os)
import os
#endif

/// Reading the user's own data without ever losing it.
///
/// Before, a file that could not be decoded (a newer or older version, a field that changed, one damaged entry) was read
/// as "empty", and the next save wrote that empty state over it. Now:
/// - lists are read entry by entry, so one bad entry no longer takes the rest with it;
/// - whenever something could not be read, the original file is first copied aside (`name.unreadable-<date>.json`),
///   so nothing is gone even after the next save.
enum SafeStorage {
    /// Where problems are reported: the system log on macOS (never the data itself, only what happened).
    nonisolated(unsafe) static var report: (String) -> Void = { message in
        #if canImport(os)
        Logger(subsystem: "nl.imdigital.nook", category: "storage").error("\(message, privacy: .public)")
        #endif
    }

    enum Outcome<Value> {
        /// No file yet: a fresh start.
        case missing
        case loaded(Value)
        /// Read, but some entries were skipped; the original was copied to `backup`.
        case partial(Value, skipped: Int, backup: URL?)
        /// Not readable at all; the original was copied to `backup`.
        case unreadable(backup: URL?, error: String)

        var value: Value? {
            switch self {
            case .loaded(let value), .partial(let value, _, _): return value
            case .missing, .unreadable: return nil
            }
        }
    }

    /// Decodes a file. `skipped` lets a lossy type say how many entries it had to leave out.
    static func load<Value: Decodable>(
        _ type: Value.Type, from url: URL, decoder: JSONDecoder = JSONDecoder(), skipped: (Value) -> Int = { _ in 0 }
    ) -> Outcome<Value> {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        return decode(type, data: data, original: url, decoder: decoder, skipped: skipped)
    }

    /// Same as `load`, for data that does not live in its own file (UserDefaults). A backup is written next to `backupBase`.
    static func decode<Value: Decodable>(
        _ type: Value.Type, data: Data, original url: URL, decoder: JSONDecoder = JSONDecoder(), skipped: (Value) -> Int = { _ in 0 }
    ) -> Outcome<Value> {
        do {
            let value = try decoder.decode(type, from: data)
            let lost = skipped(value)
            guard lost > 0 else { return .loaded(value) }
            let backup = preserve(data, for: url)
            report("\(url.lastPathComponent): skipped \(lost) unreadable entr\(lost == 1 ? "y" : "ies"); original kept at \(backup?.lastPathComponent ?? "—")")
            return .partial(value, skipped: lost, backup: backup)
        } catch {
            let backup = preserve(data, for: url)
            report("\(url.lastPathComponent) could not be read (\(error)); original kept at \(backup?.lastPathComponent ?? "—")")
            return .unreadable(backup: backup, error: String(describing: error))
        }
    }

    /// Copies the data aside, once per distinct content. Returns the backup's location.
    @discardableResult
    static func preserve(_ data: Data, for url: URL, now: Date = Date()) -> URL? {
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        // Same content already preserved: do not pile up copies on every launch.
        if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in existing where file.lastPathComponent.hasPrefix(name + ".unreadable-") {
                if (try? Data(contentsOf: file)) == data { return file }
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = folder.appendingPathComponent("\(name).unreadable-\(formatter.string(from: now)).\(ext)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: backup, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            return backup
        } catch {
            report("Could not keep a copy of \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Writes atomically, readable only by the user.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A list that decodes entry by entry: entries that cannot be read are counted and left out instead of failing the whole list.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0

    init(_ elements: [Element]) { self.elements = elements }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Step over the bad entry; decoding a placeholder moves the container forward.
                _ = try? container.decode(Skip.self)
                skipped += 1
            }
        }
    }

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension LossyArray: Encodable where Element: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}
