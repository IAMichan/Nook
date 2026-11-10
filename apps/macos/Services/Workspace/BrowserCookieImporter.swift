import Foundation
import Security
import WebKit

/// Copies the sign-ins (cookies) of another browser on this Mac into Nook's browser, once, when you ask (Settings ›
/// Browser › Import sign-ins). Later sign-ins and sign-outs stay apart in each browser. The formats are read by
/// `BrowserCookieImport`; this finds the files, asks for what macOS guards, and writes into WebKit.
///
/// - Chrome, Arc, Brave and Edge encrypt their cookies with a password in your Keychain ("Chrome Safe Storage"): macOS
///   asks whether Nook may use it, the moment you import. Nook uses it once and keeps nothing of it.
/// - Safari's cookies are only readable with Full Disk Access; without it Nook explains how to give it.
/// - Firefox's cookies are plain; only the default container is copied.
enum BrowserCookieImporter {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// The browsers that have data on this Mac.
    static func installed(home: URL = home) -> [BrowserImportSource] {
        BrowserImportSource.all.filter { FileManager.default.fileExists(atPath: $0.rootURL(home: home).path) }
    }

    /// A browser's profiles that have a cookie file.
    static func profiles(of source: BrowserImportSource, home: URL = home) -> [BrowserImportProfile] {
        let root = source.rootURL(home: home)
        let files = FileManager.default
        switch source.engine {
        case .chromium:
            var declared = (try? Data(contentsOf: root.appendingPathComponent("Local State")))
                .map(BrowserImportProfiles.chromium(localState:)) ?? []
            if declared.isEmpty {
                let folders = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
                declared = folders.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted().map { ($0, $0) }
            }
            return declared.compactMap { folder, name in
                let profile = root.appendingPathComponent(folder, isDirectory: true)
                guard let file = BrowserImportProfiles.chromiumCookieFiles(profile: profile)
                    .first(where: { files.fileExists(atPath: $0.path) }) else { return nil }
                return BrowserImportProfile(name: name, cookieFile: file)
            }
        case .firefox:
            guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
            return BrowserImportProfiles.firefox(ini: ini).compactMap { entry in
                let folder = entry.relative ? root.appendingPathComponent(entry.path, isDirectory: true)
                    : URL(fileURLWithPath: entry.path, isDirectory: true)
                let file = folder.appendingPathComponent("cookies.sqlite")
                return files.fileExists(atPath: file.path) ? BrowserImportProfile(name: entry.name, cookieFile: file) : nil
            }
        case .safari:
            // Without Full Disk Access the folder cannot be listed; the default profile is still offered, so the sheet can
            // say what is missing.
            var found = [BrowserImportProfile(name: source.name,
                                              cookieFile: root.appendingPathComponent("Cookies/Cookies.binarycookies"))]
            let stores = root.appendingPathComponent("WebKit/WebsiteDataStore", isDirectory: true)
            let folders = BrowserImportProfiles.safariProfileFolders((try? files.contentsOfDirectory(atPath: stores.path)) ?? [])
            for folder in folders {
                let file = stores.appendingPathComponent(folder).appendingPathComponent("Cookies/Cookies.binarycookies")
                if files.fileExists(atPath: file.path) {
                    found.append(BrowserImportProfile(name: tr("cookieImport.safariProfile", String(folder.prefix(8))), cookieFile: file))
                }
            }
            return found
        }
    }

    /// Whether macOS keeps the file from Nook until it has Full Disk Access (Safari). Looking does not ask anything.
    static func needsFullDiskAccess(_ file: URL) -> Bool {
        let handle = open(file.path, O_RDONLY)
        if handle >= 0 {
            close(handle)
            return false
        }
        return errno == EPERM || errno == EACCES
    }

    struct Read: Sendable {
        var cookies: [ImportedCookie]
        var skipped: Int
    }

    /// Reads a profile's cookies, from a copy so the browser's own file is never opened for writing. For a Chromium browser
    /// macOS asks first whether Nook may use its Safe Storage password. Runs off the main thread.
    static func read(_ source: BrowserImportSource, _ profile: BrowserImportProfile) async throws -> Read {
        try await Task.detached(priority: .userInitiated) {
            switch source.engine {
            case .safari:
                if needsFullDiskAccess(profile.cookieFile) { throw CookieReadError.needsFullDiskAccess }
                guard let data = try? Data(contentsOf: profile.cookieFile) else { throw CookieReadError.unreadable }
                return Read(cookies: try SafariBinaryCookies.parse(data), skipped: 0)
            case .firefox:
                return try withCopy(of: profile.cookieFile) { Read(cookies: try FirefoxCookies.read(path: $0), skipped: 0) }
            case .chromium(let service, let account):
                let key = ChromiumCookies.key(password: try safeStoragePassword(service: service, account: account))
                return try withCopy(of: profile.cookieFile) { path in
                    let result = try ChromiumCookies.read(path: path) { encrypted, host, schema in
                        ChromiumCookies.decrypt(encrypted, key: key, host: host, schema: schema)
                    }
                    return Read(cookies: result.cookies, skipped: result.skipped)
                }
            }
        }.value
    }

    /// Writes the cookies into a website data store. Returns how many it took.
    @MainActor
    static func write(_ cookies: [ImportedCookie], into stores: [WKWebsiteDataStore]) async -> Int {
        var written = 0
        for cookie in cookies {
            guard let made = httpCookie(cookie) else { continue }
            for store in stores { await store.httpCookieStore.setCookie(made) }
            written += 1
        }
        return written
    }

    /// The cookie as WebKit takes it. A host without a leading dot stays host-only, as in the browser it came from.
    static func httpCookie(_ cookie: ImportedCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: cookie.host, .path: cookie.path, .name: cookie.name, .value: cookie.value,
        ]
        if cookie.secure { properties[.secure] = "TRUE" }
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch cookie.sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        case .none, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }

    // MARK: Private

    /// The browser's Safe Storage password from the Keychain. macOS asks you whether Nook may read it.
    private static func safeStoragePassword(service: String, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { throw CookieReadError.keychainDenied }
        return password
    }

    /// Runs `body` on a copy of an SQLite file (with its journal), in a temporary folder that goes afterwards.
    private static func withCopy<T>(of file: URL, _ body: (String) throws -> T) throws -> T {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("NookCookieImport-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        do {
            try files.copyItem(at: file, to: copy)
        } catch {
            throw (error as NSError).code == NSFileReadNoPermissionError ? CookieReadError.needsFullDiskAccess : CookieReadError.unreadable
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: file.path + suffix)
            if files.fileExists(atPath: side.path) { try? files.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        return try body(copy.path)
    }
}
