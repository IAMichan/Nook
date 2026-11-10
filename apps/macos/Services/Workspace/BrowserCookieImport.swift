import Foundation
import SQLite3
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// Reading the sign-ins (cookies) of another browser on this Mac, for a one-time copy into Nook's browser (Settings ›
// Browser › Import sign-ins). Only the formats live here, in plain Swift, so they are tested with fixtures the tests make
// themselves; finding the files, asking the Keychain and writing into WebKit is `BrowserCookieImporter`.

/// One cookie as another browser kept it.
struct ImportedCookie: Equatable, Sendable {
    enum SameSite: String, Sendable { case unspecified, none, lax, strict }

    /// The host as the browser stored it: a leading dot for a cookie that also goes to subdomains.
    var host: String
    var name: String
    var value: String
    var path: String
    var secure: Bool
    var httpOnly: Bool
    /// Nil: a session cookie, gone when the browser quits.
    var expires: Date?
    var sameSite: SameSite

    /// The host without its leading dot.
    var bareHost: String { host.hasPrefix(".") ? String(host.dropFirst()) : host }
    /// Sent to subdomains too (`.example.com`), not only to the host it came from.
    var isDomainCookie: Bool { host.hasPrefix(".") }

    func isExpired(now: Date) -> Bool { expires.map { $0 <= now } ?? false }
}

/// Why reading another browser's cookies stopped.
enum CookieReadError: Error, Equatable, Sendable {
    /// Not the format expected, or cut off.
    case malformed
    /// macOS keeps the file from Nook until Nook has Full Disk Access (Safari).
    case needsFullDiskAccess
    /// The Keychain did not give the browser's cookie key (you chose Deny, or it has none).
    case keychainDenied
    /// The file is not there or cannot be opened.
    case unreadable
}

// MARK: Safari

/// Safari's `Cookies.binarycookies`: a big-endian header with page sizes, then pages whose fields are little-endian.
enum SafariBinaryCookies {
    /// Safari counts seconds from 2001-01-01, as `Date(timeIntervalSinceReferenceDate:)` does.
    private static let pageHeaderSize = 12
    private static let recordHeaderSize = 56
    private static let secureFlag: UInt32 = 0x1
    private static let httpOnlyFlag: UInt32 = 0x4

    static func parse(_ data: Data) throws -> [ImportedCookie] {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.prefix(4).elementsEqual([0x63, 0x6F, 0x6F, 0x6B]) else { throw CookieReadError.malformed }   // "cook"
        let pageCount = Int(bigEndian32(bytes, 4))
        guard pageCount >= 0, 8 + pageCount * 4 <= bytes.count else { throw CookieReadError.malformed }
        let sizes = (0..<pageCount).map { Int(bigEndian32(bytes, 8 + $0 * 4)) }
        var pageStart = 8 + pageCount * 4
        var cookies: [ImportedCookie] = []
        for size in sizes {
            guard size >= pageHeaderSize, pageStart + size <= bytes.count else { throw CookieReadError.malformed }
            let page = Array(bytes[pageStart..<(pageStart + size)])
            pageStart += size
            cookies += try parsePage(page)
        }
        return cookies
    }

    private static func parsePage(_ page: [UInt8]) throws -> [ImportedCookie] {
        let count = Int(littleEndian32(page, 4))
        let tableEnd = pageHeaderSize + count * 4
        guard count >= 0, tableEnd <= page.count else { throw CookieReadError.malformed }
        var taken: [Range<Int>] = []
        var cookies: [ImportedCookie] = []
        for index in 0..<count {
            let start = Int(littleEndian32(page, 8 + index * 4))
            guard start >= tableEnd, start + recordHeaderSize <= page.count else { throw CookieReadError.malformed }
            let size = Int(littleEndian32(page, start))
            let range = start..<(start + size)
            // A record must fit the page and not overlap another one: a damaged file never makes cookies up.
            guard size >= recordHeaderSize, range.upperBound <= page.count, !taken.contains(where: { $0.overlaps(range) })
            else { throw CookieReadError.malformed }
            taken.append(range)
            let record = Array(page[range])
            let flags = littleEndian32(record, 8)
            let offsets = [16, 20, 24, 28].map { Int(littleEndian32(record, $0)) }
            guard offsets.allSatisfy({ $0 >= recordHeaderSize && $0 < record.count }) else { throw CookieReadError.malformed }
            let expiry = Double(bitPattern: UInt64(littleEndian32(record, 40)) | UInt64(littleEndian32(record, 44)) << 32)
            let host = cString(record, offsets[0]), name = cString(record, offsets[1])
            guard !host.isEmpty, !name.isEmpty else { continue }
            let path = cString(record, offsets[2])
            cookies.append(ImportedCookie(
                host: host, name: name, value: cString(record, offsets[3]), path: path.isEmpty ? "/" : path,
                secure: flags & secureFlag != 0, httpOnly: flags & httpOnlyFlag != 0,
                expires: expiry > 0 ? Date(timeIntervalSinceReferenceDate: expiry) : nil,
                // Safari's SameSite bits are undocumented: Lax is the browsers' own default, never wider.
                sameSite: .lax))
        }
        return cookies
    }

    private static func cString(_ bytes: [UInt8], _ start: Int) -> String {
        let end = bytes[start...].firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    static func bigEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    static func littleEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

// MARK: SQLite files (Chromium, Firefox)

/// A read-only look at a copy of a browser's cookie database: the browser may hold the original open and write to it.
fileprivate final class CookieDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            throw CookieReadError.unreadable
        }
    }

    deinit { sqlite3_close(handle) }

    func columns(of table: String) -> Set<String> {
        Set(rows("PRAGMA table_info(\(table))").compactMap { $0["name"]?.text })
    }

    enum Value {
        case int(Int64), real(Double), text(String), blob([UInt8]), null
        var text: String? { if case .text(let s) = self { return s } else { return nil } }
        var int: Int64 {
            switch self {
            case .int(let n): return n
            case .real(let d): return Int64(d)
            case .text(let s): return Int64(s) ?? 0
            default: return 0
            }
        }
        var string: String {
            switch self {
            case .text(let s): return s
            case .blob(let b): return String(decoding: b, as: UTF8.self)
            case .int(let n): return String(n)
            default: return ""
            }
        }
        var bytes: [UInt8] {
            switch self {
            case .blob(let b): return b
            case .text(let s): return Array(s.utf8)
            default: return []
            }
        }
        var isNull: Bool { if case .null = self { return true } else { return false } }
    }

    func rows(_ sql: String) -> [[String: Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [[String: Value]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Value] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let base = sqlite3_column_blob(statement, column), count > 0 {
                        row[name] = .blob(Array(UnsafeRawBufferPointer(start: base, count: count)))
                    } else {
                        row[name] = .blob([])
                    }
                default: row[name] = .null
                }
            }
            result.append(row)
        }
        return result
    }
}

/// Chrome, Arc, Brave and Edge: a `Cookies` SQLite file whose values are encrypted with a key derived from the
/// "<Browser> Safe Storage" password in your Keychain.
enum ChromiumCookies {
    /// Chromium counts microseconds from 1601-01-01.
    static let epochOffset: TimeInterval = 11_644_473_600

    struct Result: Equatable, Sendable {
        var cookies: [ImportedCookie]
        /// Rows that could not be decrypted (another key, a partitioned cookie): left out.
        var skipped: Int
    }

    /// Reads a copy of the database. `decrypt` turns an encrypted value into its text (nil when it cannot).
    static func read(path: String, decrypt: (_ encrypted: [UInt8], _ host: String, _ schema: Int) -> String?) throws -> Result {
        let database = try CookieDatabase(path: path)
        let columns = database.columns(of: "cookies")
        guard columns.contains("host_key"), columns.contains("encrypted_value") else { throw CookieReadError.malformed }
        let schema = Int(database.rows("SELECT value FROM meta WHERE key = 'version'").first?["value"]?.int ?? 0)
        let partition = columns.contains("top_frame_site_key") ? "top_frame_site_key" : "'' AS top_frame_site_key"
        let sameSite = columns.contains("samesite") ? "samesite" : "-1 AS samesite"
        let rows = database.rows("""
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, \(sameSite), \(partition)
            FROM cookies
            """)
        var cookies: [ImportedCookie] = []
        var skipped = 0
        for row in rows {
            let host = row["host_key"]?.string ?? ""
            // A cookie kept for one site inside another (partitioned) has no place in a plain cookie store.
            let partitioned = !(row["top_frame_site_key"]?.string ?? "").isEmpty
            guard !partitioned, !host.isEmpty else { skipped += 1; continue }
            let encrypted = row["encrypted_value"]?.bytes ?? []
            let value: String?
            if encrypted.isEmpty { value = row["value"]?.string ?? "" } else { value = decrypt(encrypted, host, schema) }
            guard let value else { skipped += 1; continue }
            let microseconds = row["expires_utc"]?.int ?? 0
            let path = row["path"]?.string ?? ""
            cookies.append(ImportedCookie(
                host: host, name: row["name"]?.string ?? "", value: value, path: path.isEmpty ? "/" : path,
                secure: (row["is_secure"]?.int ?? 0) == 1, httpOnly: (row["is_httponly"]?.int ?? 0) == 1,
                expires: microseconds > 0 ? Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - epochOffset) : nil,
                sameSite: Self.sameSite(row["samesite"]?.int ?? -1)))
        }
        return Result(cookies: cookies, skipped: skipped)
    }

    /// Unknown values stay unspecified: guessing None would send a cookie to more sites than its browser did.
    static func sameSite(_ value: Int64) -> ImportedCookie.SameSite {
        switch value {
        case 0: return .none
        case 1: return .lax
        case 2: return .strict
        default: return .unspecified
        }
    }

    #if canImport(CommonCrypto)
    /// The AES key Chromium on the Mac derives from the Safe Storage password: PBKDF2-SHA1, salt "saltysalt", 1003 rounds.
    static func key(password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let secret = Array(password.utf8)
        _ = secret.withUnsafeBufferPointer { secretBuffer in
            secretBuffer.baseAddress!.withMemoryRebound(to: Int8.self, capacity: secret.count) { pointer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, secret.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        return key
    }

    /// One value: "v10" + AES-128-CBC (an IV of 16 spaces). From schema 24 the text starts with SHA-256 of the host, which
    /// binds it to its site; a value whose hash does not match is refused.
    static func decrypt(_ encrypted: [UInt8], key: [UInt8], host: String, schema: Int) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(decoding: encrypted.prefix(3), as: UTF8.self)
        guard prefix == "v10" || prefix == "v11" else { return nil }
        let payload = Array(encrypted.dropFirst(3))
        guard let plain = aesCBC(payload, key: key, encrypt: false) else { return nil }
        return unbound(plain, host: host, schema: schema).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The other way round, for the tests' fixtures: what Chromium writes for `value`.
    static func encrypt(_ value: String, key: [UInt8], host: String, schema: Int) -> [UInt8] {
        let plain = (schema >= 24 ? sha256(Array(host.utf8)) : []) + Array(value.utf8)
        return Array("v10".utf8) + (aesCBC(plain, key: key, encrypt: true) ?? [])
    }

    private static func unbound(_ plain: [UInt8], host: String, schema: Int) -> [UInt8]? {
        guard schema >= 24 else { return plain }
        guard plain.count >= 32, Array(plain.prefix(32)) == sha256(Array(host.utf8)) else { return nil }
        return Array(plain.dropFirst(32))
    }

    private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest
    }

    private static func aesCBC(_ input: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8]? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, input, input.count,
                             &output, output.count, &written)
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(written))
    }
    #endif
}

/// Firefox: `cookies.sqlite` in the profile folder, values in plain text.
enum FirefoxCookies {
    /// From schema 16 Firefox stores the expiry in milliseconds, before that in seconds.
    static let millisecondsSchema = 16

    static func read(path: String) throws -> [ImportedCookie] {
        let database = try CookieDatabase(path: path)
        let columns = database.columns(of: "moz_cookies")
        guard columns.contains("host"), columns.contains("value") else { throw CookieReadError.malformed }
        let schema = Int(database.rows("PRAGMA user_version").first?["user_version"]?.int ?? 0)
        let sameSite = columns.contains("sameSite") ? "sameSite" : "NULL AS sameSite"
        let raw = columns.contains("rawSameSite") ? "rawSameSite" : "NULL AS rawSameSite"
        // Containers and private windows have attributes of their own: one cookie store cannot keep them apart.
        let only = columns.contains("originAttributes") ? "WHERE originAttributes = ''" : ""
        return database.rows("""
            SELECT host, name, value, path, expiry, isSecure, isHttpOnly, \(sameSite), \(raw) FROM moz_cookies \(only)
            """).compactMap { row in
            let host = row["host"]?.string ?? "", name = row["name"]?.string ?? ""
            guard !host.isEmpty, !name.isEmpty else { return nil }
            let expiry = row["expiry"]?.int ?? 0
            let seconds = schema >= millisecondsSchema ? Double(expiry) / 1000 : Double(expiry)
            let path = row["path"]?.string ?? ""
            return ImportedCookie(
                host: host, name: name, value: row["value"]?.string ?? "", path: path.isEmpty ? "/" : path,
                secure: (row["isSecure"]?.int ?? 0) == 1, httpOnly: (row["isHttpOnly"]?.int ?? 0) == 1,
                expires: expiry > 0 ? Date(timeIntervalSince1970: seconds) : nil,
                sameSite: Self.sameSite(row["sameSite"], raw: row["rawSameSite"]))
        }
    }

    /// Schemas 10–14 turned an unset SameSite into Lax and kept what the site said in `rawSameSite`: that one counts.
    private static func sameSite(_ value: CookieDatabase.Value?, raw: CookieDatabase.Value?) -> ImportedCookie.SameSite {
        guard let value, !value.isNull else { return .unspecified }
        if value.int == 1, let raw, !raw.isNull, raw.int == 0 { return .unspecified }
        switch value.int {
        case 0: return .none
        case 1: return .lax
        case 2: return .strict
        default: return .unspecified
        }
    }
}

// MARK: Browsers and their profiles

/// A browser on this Mac whose sign-ins can be imported.
struct BrowserImportSource: Identifiable, Equatable, Sendable {
    enum Engine: Equatable, Sendable { case chromium(keychainService: String, keychainAccount: String), safari, firefox }

    let id: String
    let name: String
    let engine: Engine
    /// Where its data lives, under the home folder.
    let root: [String]

    static let all: [BrowserImportSource] = [
        BrowserImportSource(id: "chrome", name: "Google Chrome",
                            engine: .chromium(keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
                            root: ["Library", "Application Support", "Google", "Chrome"]),
        BrowserImportSource(id: "arc", name: "Arc", engine: .chromium(keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
                            root: ["Library", "Application Support", "Arc", "User Data"]),
        BrowserImportSource(id: "brave", name: "Brave",
                            engine: .chromium(keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
                            root: ["Library", "Application Support", "BraveSoftware", "Brave-Browser"]),
        BrowserImportSource(id: "edge", name: "Microsoft Edge",
                            engine: .chromium(keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
                            root: ["Library", "Application Support", "Microsoft Edge"]),
        BrowserImportSource(id: "safari", name: "Safari", engine: .safari,
                            root: ["Library", "Containers", "com.apple.Safari", "Data", "Library"]),
        BrowserImportSource(id: "firefox", name: "Firefox", engine: .firefox,
                            root: ["Library", "Application Support", "Firefox"]),
    ]

    func rootURL(home: URL) -> URL { root.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) } }
}

/// One profile of a browser and its cookie file.
struct BrowserImportProfile: Identifiable, Equatable, Sendable {
    var id: String { cookieFile.path }
    let name: String
    let cookieFile: URL
}

/// Where the profiles are, from the browser's own list. Pure: the caller reads the files.
enum BrowserImportProfiles {
    /// A profile folder named by the browser's own (user-writable) metadata: one plain name, never a path out of its root.
    static func isSafeFolder(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".")
    }

    /// Chromium's `Local State`: `profile.info_cache` names each profile folder. Sorted by folder ("Default" first).
    static func chromium(localState: Data) -> [(folder: String, name: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { folder, info -> (String, String)? in
            guard isSafeFolder(folder) else { return nil }
            let name = ((info as? [String: Any])?["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return (folder, name.isEmpty ? folder : name)
        }
        .sorted { ($0.0 == "Default" ? 0 : 1, $0.0) < ($1.0 == "Default" ? 0 : 1, $1.0) }
    }

    /// The cookie files a Chromium profile may have, the current place first (`Network/Cookies` since Chromium 96).
    static func chromiumCookieFiles(profile: URL) -> [URL] {
        [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
    }

    /// Firefox's `profiles.ini`: only `[ProfileN]` sections are profiles (`[Install…]` ones pick a default). A relative
    /// path is under the Firefox folder; a path that climbs out of it is refused.
    static func firefox(ini: String) -> [(path: String, relative: Bool, name: String)] {
        var found: [(path: String, relative: Bool, name: String)] = []
        var section: [String: String]?
        func flush() {
            if let section, let path = section["Path"], !path.isEmpty {
                let relative = section["IsRelative"] != "0"
                let parts = path.split(separator: "/")
                if !(relative && parts.contains("..")) {
                    found.append((path, relative, section["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? path))
                }
            }
            section = nil
        }
        for raw in ini.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                if line.lowercased().hasPrefix("[profile") { section = [:] }
            } else if section != nil, let equals = line.firstIndex(of: "=") {
                section?[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        flush()
        return found
    }

    /// Safari keeps the default profile's cookies in `Cookies/`, and each other profile's in a folder named by its UUID.
    static func safariProfileFolders(_ names: [String]) -> [String] {
        names.filter { UUID(uuidString: $0) != nil }.sorted()
    }
}

// MARK: Picking sites

/// The cookies of one site, for the import's list of sites to pick from.
struct CookieSite: Identifiable, Equatable, Sendable {
    var id: String { domain }
    let domain: String
    var count: Int
}

enum CookieSites {
    /// Second-level labels under a country code that are not a site of their own (`example.co.uk`).
    private static let sharedSecondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or"]

    /// The site a host belongs to: its last two labels, three under a shared second level. An IP address stays itself.
    static func site(of host: String) -> String {
        let bare = (host.hasPrefix(".") ? String(host.dropFirst()) : host).lowercased()
        let labels = bare.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ Int($0) != nil }) else { return bare }
        let last = labels[labels.count - 1], second = labels[labels.count - 2]
        let take = last.count == 2 && sharedSecondLevel.contains(second) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// The sites in the cookies that have not expired, with how many cookies each has; most cookies first.
    static func group(_ cookies: [ImportedCookie], now: Date) -> [CookieSite] {
        var counts: [String: Int] = [:]
        for cookie in cookies where !cookie.isExpired(now: now) { counts[site(of: cookie.host), default: 0] += 1 }
        return counts.map { CookieSite(domain: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.domain) > ($1.count, $0.domain) }
    }

    /// The cookies to copy: those of the chosen sites that have not expired.
    static func picking(_ cookies: [ImportedCookie], sites: Set<String>, now: Date) -> [ImportedCookie] {
        cookies.filter { !$0.isExpired(now: now) && sites.contains(site(of: $0.host)) }
    }
}
