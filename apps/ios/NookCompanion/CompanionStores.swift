import Foundation
import UIKit

// What the phone keeps for when the Mac is out of reach (docs/COMPANION.md, "When the Mac is out of reach"): the clock
// difference to each Mac, the last answer of each Mac, and actions from notifications that could not be delivered. The
// files open after the first unlock, so a notification's button can still read and write them later while locked.

/// How far this phone's clock is from each Mac's (`CompanionClock`), by the Mac's pairing id: added to the time of every
/// request to that Mac (`CompanionChannel.frame`). Learned from a `stale` refusal that says the Mac's time.
enum ClockOffsets {
    private static let lock = NSLock()
    private static var cache: [String: TimeInterval] = [:]

    private static func defaultsKey(_ mac: String) -> String { "companion.clockOffset." + mac }

    static func offset(for mac: String) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        if let value = cache[mac] { return value }
        let value = UserDefaults.standard.double(forKey: defaultsKey(mac))
        cache[mac] = value
        return value
    }

    /// Takes in the Mac's time from a `stale` refusal (`CompanionFeature.clock`). True when the offset moved enough that
    /// trying again at once can help; false for any other answer, or when the clock was not the problem.
    @discardableResult
    static func learn(from response: CompanionResponse, mac: String, now: Date = Date()) -> Bool {
        guard response.error == .stale, let macTime = response.macTime,
              let next = CompanionClock.offset(macTime: macTime, phoneTime: now.timeIntervalSince1970),
              CompanionClock.changed(offset(for: mac), next) else { return false }
        lock.lock()
        cache[mac] = next
        lock.unlock()
        UserDefaults.standard.set(next, forKey: defaultsKey(mac))
        CompanionDiagnosticsLog.phone.record("clock", ["offset": String(Int(next))])
        return true
    }

    static func forget(_ mac: String) {
        lock.lock()
        cache[mac] = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: defaultsKey(mac))
    }
}

/// A file in the app's Application Support that opens after the first unlock.
private enum SupportFile {
    static func url(_ name: String) -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(name)
    }

    static func read<Value: Decodable>(_ name: String, as type: Value.Type) -> Value? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func write<Value: Encodable>(_ value: Value, _ name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        guard let url = url(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The last the phone saw of each Mac (`CompanionCache`), one file per Mac: `companion-cache-<id>.json`.
/// Saving encodes and writes on a serial queue: the cache holds whole conversations and is saved every few seconds
/// while one streams, which was too much for the main thread. Removing and loading go through the same queue, so they
/// come after every save asked for before them and the last save wins.
enum CacheStore {
    private static let queue = DispatchQueue(label: "nook.companion.cache-store", qos: .utility)

    private static func name(_ mac: String) -> String { "companion-cache-\(mac).json" }

    static func load(mac: String) -> CompanionCache {
        queue.sync { SupportFile.read(name(mac), as: CompanionCache.self) } ?? CompanionCache()
    }

    static func save(_ cache: CompanionCache, mac: String) {
        let file = name(mac)
        queue.async { SupportFile.write(cache, file) }
    }

    static func remove(mac: String) {
        let file = name(mac)
        queue.async { SupportFile.remove(file) }
    }
}

/// The pull requests the phone saw of each Mac (`PullCache`), one file per Mac: `companion-pulls-<id>.json`.
enum PullCacheStore {
    private static func name(_ mac: String) -> String { "companion-pulls-\(mac).json" }

    static func load(mac: String) -> PullCache { SupportFile.read(name(mac), as: PullCache.self) ?? PullCache() }
    static func save(_ cache: PullCache, mac: String) { SupportFile.write(cache, name(mac)) }
    static func remove(mac: String) { SupportFile.remove(name(mac)) }
}

/// Deny and Reply buttons that could not reach their Mac (`NotificationRetries`), across all Macs.
enum RetryStore {
    private static let name = "companion-notification-retries.json"

    static func load() -> NotificationRetries { SupportFile.read(name, as: NotificationRetries.self) ?? NotificationRetries() }

    static func save(_ retries: NotificationRetries) {
        if retries.entries.isEmpty { SupportFile.remove(name) } else { SupportFile.write(retries, name) }
    }
}

/// Keeps the app running for a short while in the background (a notification's button, the app going to the
/// background), so a request that started can finish.
@MainActor
final class BackgroundWork {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        // The expiry handler runs on the main thread and must end the task before it returns.
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
