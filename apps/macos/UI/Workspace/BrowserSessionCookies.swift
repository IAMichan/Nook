import Foundation
import WebKit

/// Keeps a browser's session cookies between launches, for a browser that keeps sign-ins (`BrowserProfiles`, Keep).
///
/// Many sites keep you signed in with a cookie without an end date, a "session cookie". WebKit's own store drops those
/// when Nook quits, so you had to sign in again after every launch even with sign-ins kept. Chrome and Safari keep
/// them when they reopen your tabs; Nook does the same: it copies them to a file of its own while you browse and puts
/// them back when the browser starts. A site that signs you out removes the cookie, and the next copy leaves it out.
@MainActor
enum BrowserSessionCookies {
    /// One session cookie as written to disk.
    struct Saved: Codable, Equatable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?
    }

    private static var folder: URL { NookPaths.supportDirectory.appendingPathComponent("BrowserSessions", isDirectory: true) }
    /// Kept cookies older than this are not put back: a session cookie is not meant to last for ever.
    private static let maxAge: TimeInterval = 30 * 86_400

    /// The stores whose session cookies are kept, by their id.
    private static var adopted: [UUID: WKWebsiteDataStore] = [:]
    /// What was written last per store, so an unchanged set is not written again.
    private static var written: [UUID: Data] = [:]
    private static var timer: Timer?
    private static var pending: Task<Void, Never>?

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }

    /// A browser that keeps sign-ins got its store: put its session cookies back, then keep copying them.
    static func adopt(_ store: WKWebsiteDataStore, id: UUID) {
        guard adopted[id] == nil else { return }
        adopted[id] = store
        restore(into: store, id: id)
        if timer == nil {
            // Every two minutes, besides after each page (`pageLoaded`): what a crash or a forced quit loses at most.
            timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
                MainActor.assumeIsolated { saveAll() }
            }
        }
    }

    /// The store stopped keeping sign-ins: its copied cookies go too.
    static func forget(id: UUID) {
        adopted[id] = nil
        written[id] = nil
        try? FileManager.default.removeItem(at: file(id))
    }

    /// A page finished loading: copy a moment later, once its cookies are set.
    static func pageLoaded() {
        guard !adopted.isEmpty else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            saveAll()
        }
    }

    static func saveAll() {
        for (id, store) in adopted { save(store, id: id) }
    }

    private static func save(_ store: WKWebsiteDataStore, id: UUID) {
        store.httpCookieStore.getAllCookies { cookies in
            let saved = cookies.filter(\.isSessionOnly).map { cookie in
                Saved(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                      secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue)
            }
            MainActor.assumeIsolated {
                guard adopted[id] != nil, let data = try? JSONEncoder().encode(saved), data != written[id] else { return }
                written[id] = data
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                try? data.write(to: file(id), options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
            }
        }
    }

    private static func restore(into store: WKWebsiteDataStore, id: UUID) {
        let url = file(id)
        guard let data = try? Data(contentsOf: url),
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(date) < maxAge,
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        written[id] = data
        for item in saved {
            guard let cookie = cookie(from: item) else { continue }
            store.httpCookieStore.setCookie(cookie)
        }
    }

    /// The cookie again, still a session cookie (no end date), so it is copied again while it lives.
    static func cookie(from item: Saved) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: item.name,
            .value: item.value,
            .domain: item.domain,
            .path: item.path.isEmpty ? "/" : item.path
        ]
        if item.secure { properties[.secure] = "TRUE" }
        if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = item.sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
