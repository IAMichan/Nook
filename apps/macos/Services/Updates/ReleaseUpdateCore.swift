import Foundation

// Updates for a downloaded build (the .dmg or .zip from GitHub Releases), which has no checkout to rebuild from: Nook
// asks GitHub for a newer release, downloads its .zip, checks the Ed25519 signature that the release workflow made with
// the project's private key against the public key in Info.plist, and puts the app in place. Everything here is
// Foundation only, so it is tested on Linux; the signature check itself (CryptoKit) sits behind `UpdateSignatureVerifier`.

/// A release version as the tags write it: `v0.2.0`, `v0.2.0-beta.3`. Ordered like SemVer: a pre-release comes before
/// its release, and its dot-separated parts compare numerically when both are numbers.
struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// "beta.3" → ["beta", "3"]; empty for a regular release.
    let prerelease: [String]

    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        // Build metadata (+…) does not take part in the order.
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var suffix: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            suffix = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !suffix.isEmpty, suffix.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } })
            else { return nil }
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = suffix
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // 1.0.0-beta.1 < 1.0.0
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            // Numeric parts come before alphanumeric ones.
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// What a downloaded build knows about itself, as the release workflow wrote it into Info.plist. Nil for a build that
/// was not made by the release workflow (a build from a checkout has `BuildSource` instead).
struct ReleaseBuild: Equatable, Sendable {
    /// The full version with its pre-release part (`NookReleaseVersion`, e.g. 0.2.0-beta.3).
    let version: ReleaseVersion
    /// The GitHub repository the releases come from, "owner/name".
    let repository: String
    /// The Ed25519 public key (32 bytes) that signs the update's .zip; nil when the build carries none, and then Nook
    /// can say a newer release exists but never installs one it cannot check.
    let publicKey: Data?

    static let defaultRepository = "IAMichan/nook"

    init?(info: [String: Any]) {
        guard let text = Self.value(info["NookReleaseVersion"]), let version = ReleaseVersion(text) else { return nil }
        self.version = version
        let repository = Self.value(info["NookReleaseRepository"]) ?? Self.defaultRepository
        self.repository = Self.isRepository(repository) ? repository : Self.defaultRepository
        self.publicKey = Self.value(info["NookUpdatePublicKey"]).flatMap(UpdateSignature.publicKey(base64:))
    }

    init(version: ReleaseVersion, repository: String = defaultRepository, publicKey: Data?) {
        self.version = version
        self.repository = repository
        self.publicKey = publicKey
    }

    /// Betas follow betas: a beta build is offered newer betas and releases, a regular release only regular releases.
    var includesPrereleases: Bool { version.isPrerelease }

    /// GitHub's list of releases, newest first.
    var releasesURL: URL? { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") }

    static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".."
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    private static func value(_ any: Any?) -> String? {
        guard let text = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else { return nil }
        return text
    }
}

/// One release as GitHub's API describes it (only what the update needs).
struct GitHubRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let url: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case url = "browser_download_url"
        }
    }

    let tag: String
    let name: String?
    let draft: Bool
    let prerelease: Bool
    let page: URL?
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, draft, prerelease, assets
        case tag = "tag_name"
        case page = "html_url"
        case publishedAt = "published_at"
    }

    init(tag: String, name: String? = nil, draft: Bool = false, prerelease: Bool = false, page: URL? = nil,
         publishedAt: String? = nil, assets: [Asset]) {
        self.tag = tag
        self.name = name
        self.draft = draft
        self.prerelease = prerelease
        self.page = page
        self.publishedAt = publishedAt
        self.assets = assets
    }

    /// The list `GET /repos/{owner}/{repo}/releases` returns; releases that do not parse are left out.
    static func list(from data: Data) -> [GitHubRelease] {
        struct Lenient: Decodable {
            let release: GitHubRelease?
            init(from decoder: Decoder) throws { release = try? GitHubRelease(from: decoder) }
        }
        return ((try? JSONDecoder().decode([Lenient].self, from: data)) ?? []).compactMap(\.release)
    }
}

/// A newer release this build can install: its .zip and the signature of that .zip.
struct ReleaseCandidate: Equatable, Sendable {
    let version: ReleaseVersion
    let title: String
    let page: URL?
    let archive: GitHubRelease.Asset
    let signature: GitHubRelease.Asset
}

/// What the check found.
enum ReleaseCheck: Equatable, Sendable {
    case upToDate
    case available(ReleaseCandidate)
    /// A newer release exists but carries no signature (or this build has no key to check one): it is shown with a link
    /// to download it by hand, never installed.
    case unsigned(version: ReleaseVersion, page: URL?)
}

enum ReleaseSelection {
    /// The release workflow's file names: Nook-<version>-macOS.zip and, next to it, Nook-<version>-macOS.zip.sig.
    static func archiveName(_ version: ReleaseVersion) -> String { "Nook-\(version)-macOS.zip" }
    static func signatureName(_ version: ReleaseVersion) -> String { archiveName(version) + ".sig" }

    /// The newest release after `build` on its channel, with the assets the install needs. A .zip over 1 GB or a
    /// signature over 1 KB is not what the workflow makes and is skipped.
    static func check(_ releases: [GitHubRelease], for build: ReleaseBuild) -> ReleaseCheck {
        let newer = releases.compactMap { release -> (ReleaseVersion, GitHubRelease)? in
            guard !release.draft, let version = ReleaseVersion(release.tag), version > build.version,
                  build.includesPrereleases || (!version.isPrerelease && !release.prerelease) else { return nil }
            return (version, release)
        }
        guard let newest = newer.max(by: { $0.0 < $1.0 }) else { return .upToDate }
        let (version, release) = newest
        let archive = release.assets.first { $0.name == archiveName(version) && $0.size > 0 && $0.size < 1_000_000_000 }
        let signature = release.assets.first { $0.name == signatureName(version) && $0.size > 0 && $0.size < 1_024 }
        guard build.publicKey != nil, let archive, let signature, isGitHubDownload(archive.url), isGitHubDownload(signature.url)
        else { return .unsigned(version: version, page: release.page) }
        let title = release.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Nook \(version)"
        return .available(ReleaseCandidate(version: version, title: title, page: release.page, archive: archive, signature: signature))
    }

    /// Downloads come from GitHub over HTTPS (the signature is what makes them trusted; this keeps the URL honest).
    static func isGitHubDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }
}

/// Checks an Ed25519 signature. CryptoKit on the Mac (`Ed25519Verifier`); tests use their own.
protocol UpdateSignatureVerifier: Sendable {
    func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool
}

enum UpdateSignature {
    static let publicKeyLength = 32
    static let signatureLength = 64

    /// The public key as Info.plist holds it: base64 of the 32 raw bytes.
    static func publicKey(base64 text: String) -> Data? {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == publicKeyLength else { return nil }
        return data
    }

    /// The .sig file: base64 of the 64-byte signature, on one line (scripts/sign-update.swift writes it).
    static func decode(_ file: Data) -> Data? {
        guard let text = String(data: file, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: text), data.count == signatureLength else { return nil }
        return data
    }

    /// The downloaded .zip is genuine: signed with the private key that belongs to the build's public key.
    static func verify(archive: Data, signatureFile: Data, publicKey: Data, using verifier: UpdateSignatureVerifier) -> Bool {
        guard publicKey.count == publicKeyLength, let signature = decode(signatureFile) else { return false }
        return verifier.isValid(signature: signature, of: archive, publicKey: publicKey)
    }
}

/// What the unpacked app must say about itself before it replaces this one: the same app, and exactly the version the
/// release promised. The version is inside the signed .zip, so an older signed .zip renamed as a newer release (a
/// downgrade) is refused here.
enum ReleaseBundleCheck {
    enum Problem: Equatable, Sendable { case notNook, wrongVersion(String?) }

    static func problem(info: [String: Any], bundleIdentifier: String, expected: ReleaseVersion) -> Problem? {
        guard (info["CFBundleIdentifier"] as? String) == bundleIdentifier else { return .notNook }
        let version = info["NookReleaseVersion"] as? String
        guard let version, ReleaseVersion(version) == expected else { return .wrongVersion(version) }
        return nil
    }
}
