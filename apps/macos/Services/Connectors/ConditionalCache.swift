import Foundation

/// Answers kept for conditional reads: a read that polls sends the `ETag` of the last answer, and a forge with nothing new
/// says 304 without a body. On GitHub such a read does not count against the rate limit, and a pull request page or a
/// session's badge asks every 30 seconds, five requests at a time.
///
/// Only in memory and only for the reads that ask for it (`ConditionalFetch`): this is not an HTTP cache. Nothing is
/// answered from here unless the forge just said it is still current, so it can never show a merged pull request as open.
final class ConditionalCache: @unchecked Sendable {
    struct Entry: Equatable {
        var etag: String
        var body: Data
        var used: UInt64
    }

    static let shared: ConditionalCache = {
        let cache = ConditionalCache()
        MemoryPressure.shared.register("conditionalCache") { [cache] _ in cache.removeAll() }
        return cache
    }()

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private let byteLimit: Int
    private let bodyLimit: Int

    /// - Parameters:
    ///   - byteLimit: what the kept answers may hold together; the longest unused go first.
    ///   - bodyLimit: a larger answer is not kept.
    ///   4 MB holds a few hundred pull request pages and badges, which is what polls; a page not asked for a while is
    ///   simply read in full again.
    init(byteLimit: Int = 4 * 1024 * 1024, bodyLimit: Int = 1024 * 1024) {
        self.byteLimit = byteLimit
        self.bodyLimit = bodyLimit
    }

    /// The key of a request: its address and all its headers, since an answer differs per account and each forge signs in
    /// with a header of its own. The credential itself stays out of it; the keys live as long as Nook runs.
    static func key(_ request: URLRequest) -> String? {
        guard let url = request.url?.absoluteString else { return nil }
        var who = Hasher()
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            who.combine(name.lowercased())
            who.combine(value)
        }
        return "\(who.finalize())|\(url)"
    }

    func entry(_ key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.used = clock
        entries[key] = entry
        return entry
    }

    func store(_ key: String, etag: String, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        remove(key)
        guard body.count <= bodyLimit else { return }
        clock += 1
        // A copy of just the body: what URLSession hands over can be a view into larger network buffers, kept alive with it.
        let body = body.withUnsafeBytes { Data($0) }
        entries[key] = Entry(etag: etag, body: body, used: clock)
        bytes += body.count
        while bytes > byteLimit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { remove(oldest) }
    }

    /// The bytes the kept answers hold.
    var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    /// Lets every kept answer go (memory pressure): the next read of each is a full one.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        bytes = 0
    }

    func forget(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        remove(key)
    }

    /// Call with the lock held.
    private func remove(_ key: String) {
        if let gone = entries.removeValue(forKey: key) { bytes -= gone.body.count }
    }
}

/// A GET that asks whether the last answer still holds. Callers see an ordinary 200 with the whole body, so a parser
/// never has to know about it.
enum ConditionalFetch {
    static func data(for request: URLRequest, session: URLSession,
                     cache: ConditionalCache = .shared) async throws -> (Data, URLResponse) {
        guard (request.httpMethod ?? "GET") == "GET", let key = ConditionalCache.key(request) else {
            return try await session.data(for: request)
        }
        var request = request
        let known = cache.entry(key)
        if let known { request.setValue(known.etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, response) }
        if http.statusCode == 304, let known, let url = http.url ?? request.url {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
                if let name = field.key as? String, let value = field.value as? String { result[name] = value }
            }
            let answer = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers) ?? http
            return (known.body, answer)
        }
        if http.statusCode == 200, let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            cache.store(key, etag: etag, body: data)
        } else if known != nil {
            cache.forget(key)
        }
        return (data, response)
    }
}
