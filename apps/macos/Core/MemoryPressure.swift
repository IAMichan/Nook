import Foundation

/// One place that hears when macOS runs low on memory, for every model, cache and web view that can let something go.
///
/// A part registers a purge under a key (registering the same key again replaces it) and drops what it can rebuild when
/// the system warns. One dispatch source serves them all; it starts with the first registration. Purges run on the main
/// queue, one after another.
final class MemoryPressure: @unchecked Sendable {
    static let shared = MemoryPressure()

    enum Level: Sendable { case warning, critical }

    typealias Purge = @Sendable (Level) -> Void

    private let lock = NSLock()
    private var purges: [String: Purge] = [:]
    /// Keys in the order they registered, so purges run in a stable order.
    private var order: [String] = []
    #if canImport(Darwin)
    private var source: DispatchSourceMemoryPressure?
    #endif

    init() {}

    /// Registers `purge` under `key`; it is called on the main queue when memory runs low.
    func register(_ key: String, purge: @escaping Purge) {
        lock.lock()
        if purges.updateValue(purge, forKey: key) == nil { order.append(key) }
        lock.unlock()
        startIfNeeded()
    }

    func unregister(_ key: String) {
        lock.lock()
        purges[key] = nil
        order.removeAll { $0 == key }
        lock.unlock()
    }

    var registered: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    /// Runs every registered purge now (what a pressure event does; tests call it directly).
    func purge(_ level: Level) {
        lock.lock()
        let all = order.compactMap { purges[$0] }
        lock.unlock()
        for purge in all { purge(level) }
    }

    private func startIfNeeded() {
        #if canImport(Darwin)
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.purge(source.data.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        self.source = source
        #endif
    }
}
