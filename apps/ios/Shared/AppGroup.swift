import Foundation

/// The app group the app and its extensions share (`group.nl.imdigital.nook.companion`): what the usage widget shows, what
/// the share sheet may offer, and what was shared and waits for the app. Each is a small JSON file that opens after the
/// first unlock, so a widget or the share sheet can read it while the phone is locked again. Session titles and limits
/// stay on the phone: only the app and its own extensions can read the group.
enum AppGroup {
    static let identifier = "group.nl.imdigital.nook.companion"

    static func url(_ name: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?.appendingPathComponent(name)
    }

    static func read<Value: Decodable>(_ name: String, as type: Value.Type) -> Value? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    @discardableResult
    static func write<Value: Encodable>(_ value: Value, _ name: String) -> Bool {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func remove(_ name: String) {
        guard let url = url(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Changes a file under a lock shared with the other processes (the app and the share sheet both write the queue).
    static func update<Value: Codable>(_ name: String, empty: Value, _ change: (inout Value) -> Void) {
        guard let url = url(name) else { return }
        let coordinator = NSFileCoordinator()
        var failure: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &failure) { place in
            var value = (try? Data(contentsOf: place)).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } ?? empty
            change(&value)
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: place, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    static let shareQueue = "share-queue.json"
    static let shareTargets = "share-targets.json"
}

/// The usage widget's kind, for the app to ask WidgetKit to read it again.
enum UsageWidgetKind {
    static let kind = "NookUsage"
}
