import Foundation

// A local log of how the companion connects (docs/COMPANION.md, "Diagnostics"): the route chosen and how long the checks
// took, why a connection was replaced, close codes and refusals, the relay's state. One JSON object per line (NDJSON),
// size-capped with one older file kept. It never leaves the device by itself: *Copy diagnostics* puts a redacted copy on
// the clipboard for the user to paste where they choose.

struct CompanionLogEvent: Codable, Equatable, Sendable {
    /// Seconds since 1970.
    var at: Double
    /// What happened: "route", "probe", "reconnect", "closed", "refused", "relay", …
    var event: String
    var fields: [String: String]
}

final class CompanionDiagnosticsLog: @unchecked Sendable {
    let url: URL
    let maxBytes: Int
    private let lock = NSLock()

    /// The file before the current one; it is dropped when the current one fills up again.
    var olderURL: URL { url.appendingPathExtension("1") }

    init(url: URL, maxBytes: Int = 256 * 1024) {
        self.url = url
        self.maxBytes = max(1024, maxBytes)
    }

    /// Adds one line. Field values are cut to 300 characters; the log is about connections, not content.
    func record(_ event: String, _ fields: [String: String] = [:], now: Date = Date()) {
        let entry = CompanionLogEvent(at: (now.timeIntervalSince1970 * 1000).rounded() / 1000, event: event,
                                      fields: fields.mapValues { String($0.prefix(300)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + line.count > maxBytes {
            try? manager.removeItem(at: olderURL)
            try? manager.moveItem(at: url, to: olderURL)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Every event still kept, oldest first; a line that cannot be read is skipped.
    func events() -> [CompanionLogEvent] {
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder()
        return [olderURL, url].flatMap { file -> [CompanionLogEvent] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(CompanionLogEvent.self, from: Data($0.utf8)) }
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: olderURL)
    }

    /// What *Copy diagnostics* puts on the clipboard: a header (`about`, e.g. versions and what is set up), then the newest
    /// `limit` events as NDJSON, every line redacted (`CompanionRedaction`).
    func bundle(about: [String: String], limit: Int = 400) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = ["# Nook companion diagnostics (addresses, names and keys removed)"]
        for key in about.keys.sorted() { lines.append("# \(key): \(CompanionRedaction.redact(about[key] ?? ""))") }
        for event in events().suffix(limit) {
            guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else { continue }
            lines.append(CompanionRedaction.redact(text))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Takes out of a diagnostics line what could identify the user or a device: addresses become the kind of network they
/// belong to, host names and relay addresses a placeholder, and ids, rooms, keys and tokens disappear.
enum CompanionRedaction {
    private static let rules: [(NSRegularExpression, (String) -> String)] = {
        func rule(_ pattern: String, _ replace: @escaping (String) -> String) -> (NSRegularExpression, (String) -> String) {
            (try! NSRegularExpression(pattern: pattern), replace)
        }
        return [
            // URLs (a relay): the scheme stays.
            rule(#"\b(https?|wss?)://[^\s"/]+[^\s"]*"#) { match in (match.components(separatedBy: "://").first ?? "https") + "://<relay>" },
            // Long base64 or base64url runs with a digit in them: keys, tokens, sealed bytes (not long words).
            rule(#"(?=[A-Za-z0-9+/_\-]*[0-9])[A-Za-z0-9+/_\-]{24,}={0,2}"#) { _ in "<secret>" },
            // Hex ids (device ids, rooms, push tokens).
            rule(#"\b[0-9a-fA-F]{16,}\b"#) { _ in "<id>" },
            // IPv4 addresses: the kind of network.
            rule(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) { match in "<\(CompanionAddress.classify(match).rawValue)>" },
            // IPv6 addresses (at least three groups).
            rule(#"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4}\b"#) { match in "<\(CompanionAddress.classify(match).rawValue)6>" },
            // Host names on the local network or a tailnet.
            rule(#"\b[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.(local|ts\.net)\b"#) { match in
                match.hasSuffix(".ts.net") ? "<host>.ts.net" : "<host>.local"
            },
        ]
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for (expression, replace) in rules {
            let matches = expression.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: replace(String(result[range])))
            }
        }
        return result
    }
}
