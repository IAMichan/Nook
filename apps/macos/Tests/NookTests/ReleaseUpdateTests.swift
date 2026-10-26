import XCTest

/// Updating a downloaded build from GitHub Releases: versions, which release and which files, and the signature check.
final class ReleaseUpdateTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    private func asset(_ name: String, size: Int = 10) -> GitHubRelease.Asset {
        GitHubRelease.Asset(name: name, url: URL(string: "https://github.com/IAMichan/nook/releases/download/x/\(name)")!, size: size)
    }

    private func release(_ tag: String, prerelease: Bool? = nil, signed: Bool = true, draft: Bool = false) -> GitHubRelease {
        let version = ReleaseVersion(tag)!
        var assets = [asset("Nook-\(version)-macOS.dmg"), asset("Nook-\(version)-macOS.zip"), asset("SHA256SUMS.txt")]
        if signed { assets.append(asset("Nook-\(version)-macOS.zip.sig", size: 89)) }
        return GitHubRelease(tag: tag, name: "Nook \(version)", draft: draft, prerelease: prerelease ?? version.isPrerelease,
                             page: URL(string: "https://github.com/IAMichan/nook/releases/tag/\(tag)"), assets: assets)
    }

    func testVersionsParseAndOrderLikeSemVer() {
        XCTAssertEqual(ReleaseVersion("v0.2.0-beta.3")?.description, "0.2.0-beta.3")
        XCTAssertEqual(ReleaseVersion("1.2.3")?.prerelease, [])
        XCTAssertEqual(ReleaseVersion("v1.2.3+build.5")?.description, "1.2.3")
        for bad in ["", "v1", "1.2", "1.2.3.4", "v1.2.x", "1.2.3-", "1.2.3-beta..1", "1.2.3-bèta", "-1.2.3"] {
            XCTAssertNil(ReleaseVersion(bad), bad)
        }
        let ordered = ["0.1.0-alpha", "0.1.0-beta", "0.1.0-beta.2", "0.1.0-beta.10", "0.1.0-beta.10.1", "0.1.0-rc.1",
                       "0.1.0", "0.1.1-beta.1", "0.1.1", "0.2.0", "1.0.0"].map { ReleaseVersion($0)! }
        XCTAssertEqual(ordered.shuffled().sorted(), ordered)
        XCTAssertLessThan(ReleaseVersion("1.0.0-1")!, ReleaseVersion("1.0.0-beta")!, "numbers before words")
        XCTAssertEqual(ReleaseVersion("v1.0.0"), ReleaseVersion("1.0.0"))
    }

    func testBuildComesFromInfoPlist() {
        let info: [String: Any] = ["NookReleaseVersion": "0.3.0-beta.2", "NookReleaseRepository": "someone/fork",
                                   "NookUpdatePublicKey": key.base64EncodedString()]
        let build = ReleaseBuild(info: info)
        XCTAssertEqual(build?.version, ReleaseVersion("0.3.0-beta.2"))
        XCTAssertEqual(build?.repository, "someone/fork")
        XCTAssertEqual(build?.publicKey, key)
        XCTAssertEqual(build?.includesPrereleases, true)
        XCTAssertEqual(build?.releasesURL?.absoluteString, "https://api.github.com/repos/someone/fork/releases?per_page=20")

        XCTAssertNil(ReleaseBuild(info: ["CFBundleShortVersionString": "0.3.0"]), "not made by the release workflow")
        let plain = ReleaseBuild(info: ["NookReleaseVersion": "1.0.0", "NookUpdatePublicKey": "$(NOOK_UPDATE_PUBLIC_KEY)",
                                        "NookReleaseRepository": "../../evil"])
        XCTAssertNil(plain?.publicKey, "an unexpanded key is no key")
        XCTAssertEqual(plain?.repository, "IAMichan/nook")
        XCTAssertNil(ReleaseBuild(info: ["NookReleaseVersion": "1.0.0", "NookUpdatePublicKey": "c2hvcnQ="])?.publicKey, "too short")
    }

    func testPicksTheNewestReleaseOnTheBuildsChannel() {
        let releases = [release("v0.3.0-beta.1"), release("v0.2.1"), release("v0.2.0"), release("v0.4.0", draft: true)]
        let beta = ReleaseBuild(version: ReleaseVersion("0.2.0-beta.4")!, publicKey: key)
        guard case .available(let candidate) = ReleaseSelection.check(releases, for: beta) else { return XCTFail() }
        XCTAssertEqual(candidate.version, ReleaseVersion("0.3.0-beta.1"), "a beta build follows betas; drafts never count")
        XCTAssertEqual(candidate.archive.name, "Nook-0.3.0-beta.1-macOS.zip")
        XCTAssertEqual(candidate.signature.name, "Nook-0.3.0-beta.1-macOS.zip.sig")
        XCTAssertEqual(candidate.title, "Nook 0.3.0-beta.1")

        let stable = ReleaseBuild(version: ReleaseVersion("0.2.0")!, publicKey: key)
        guard case .available(let next) = ReleaseSelection.check(releases, for: stable) else { return XCTFail() }
        XCTAssertEqual(next.version, ReleaseVersion("0.2.1"), "a regular release is offered regular releases only")

        let newest = ReleaseBuild(version: ReleaseVersion("0.3.0")!, publicKey: key)
        XCTAssertEqual(ReleaseSelection.check(releases, for: newest), .upToDate)
        XCTAssertEqual(ReleaseSelection.check([], for: newest), .upToDate)
        // A release marked pre-release on GitHub stays off the stable channel even with a plain tag.
        XCTAssertEqual(ReleaseSelection.check([release("v0.2.5", prerelease: true)], for: stable), .upToDate)
    }

    func testNeverOffersWhatCannotBeChecked() {
        let build = ReleaseBuild(version: ReleaseVersion("0.2.0")!, publicKey: key)
        let unsigned = release("v0.2.1", signed: false)
        XCTAssertEqual(ReleaseSelection.check([unsigned], for: build), .unsigned(version: ReleaseVersion("0.2.1")!, page: unsigned.page))

        let keyless = ReleaseBuild(version: ReleaseVersion("0.2.0")!, publicKey: nil)
        guard case .unsigned = ReleaseSelection.check([release("v0.2.1")], for: keyless) else { return XCTFail("no key, no install") }

        let elsewhere = GitHubRelease(tag: "v0.2.1", assets: [
            GitHubRelease.Asset(name: "Nook-0.2.1-macOS.zip", url: URL(string: "http://example.com/Nook.zip")!, size: 10),
            asset("Nook-0.2.1-macOS.zip.sig"),
        ])
        guard case .unsigned = ReleaseSelection.check([elsewhere], for: build) else { return XCTFail("not from GitHub over https") }
        XCTAssertTrue(ReleaseSelection.isGitHubDownload(URL(string: "https://objects.githubusercontent.com/a")!))
        XCTAssertFalse(ReleaseSelection.isGitHubDownload(URL(string: "https://github.com.evil.example/a")!))
    }

    func testReadsGitHubsReleaseList() {
        let json = """
        [{"tag_name": "v0.2.1", "name": "Nook 0.2.1", "draft": false, "prerelease": false,
          "html_url": "https://github.com/IAMichan/nook/releases/tag/v0.2.1", "published_at": "2026-10-01T10:00:00Z",
          "assets": [{"name": "Nook-0.2.1-macOS.zip", "size": 1234,
                      "browser_download_url": "https://github.com/IAMichan/nook/releases/download/v0.2.1/Nook-0.2.1-macOS.zip"}]},
         {"tag_name": 5}]
        """
        let releases = GitHubRelease.list(from: Data(json.utf8))
        XCTAssertEqual(releases.count, 1, "a release that does not parse is skipped, not fatal")
        XCTAssertEqual(releases.first?.assets.first?.size, 1234)
        XCTAssertEqual(GitHubRelease.list(from: Data("{\"message\": \"rate limited\"}".utf8)), [])
    }

    private struct Recorder: UpdateSignatureVerifier {
        let valid: Bool
        func isValid(signature: Data, of message: Data, publicKey: Data) -> Bool {
            valid && signature.count == 64 && publicKey.count == 32 && message == Data("zip".utf8)
        }
    }

    func testSignatureFileAndKeyChecks() {
        let signature = Data(repeating: 1, count: 64)
        let file = Data((signature.base64EncodedString() + "\n").utf8)
        XCTAssertEqual(UpdateSignature.decode(file), signature)
        XCTAssertNil(UpdateSignature.decode(Data("not base64".utf8)))
        XCTAssertNil(UpdateSignature.decode(Data(Data(repeating: 1, count: 63).base64EncodedString().utf8)))

        XCTAssertTrue(UpdateSignature.verify(archive: Data("zip".utf8), signatureFile: file, publicKey: key, using: Recorder(valid: true)))
        XCTAssertFalse(UpdateSignature.verify(archive: Data("zip".utf8), signatureFile: file, publicKey: key, using: Recorder(valid: false)))
        XCTAssertFalse(UpdateSignature.verify(archive: Data("zip".utf8), signatureFile: Data(), publicKey: key, using: Recorder(valid: true)))
        XCTAssertFalse(UpdateSignature.verify(archive: Data("zip".utf8), signatureFile: file, publicKey: Data([1]), using: Recorder(valid: true)))
    }

    func testUnpackedAppMustBeNookAtThePromisedVersion() {
        let expected = ReleaseVersion("0.2.1")!
        XCTAssertNil(ReleaseBundleCheck.problem(info: ["CFBundleIdentifier": "nl.imdigital.nook", "NookReleaseVersion": "0.2.1"],
                                                bundleIdentifier: "nl.imdigital.nook", expected: expected))
        XCTAssertEqual(ReleaseBundleCheck.problem(info: ["CFBundleIdentifier": "com.other", "NookReleaseVersion": "0.2.1"],
                                                  bundleIdentifier: "nl.imdigital.nook", expected: expected), .notNook)
        XCTAssertEqual(ReleaseBundleCheck.problem(info: ["CFBundleIdentifier": "nl.imdigital.nook", "NookReleaseVersion": "0.1.0"],
                                                  bundleIdentifier: "nl.imdigital.nook", expected: expected), .wrongVersion("0.1.0"),
                       "an older signed build renamed as a newer release")
    }

    func testStepsAndReceiptOfEachKindOfInstall() {
        XCTAssertEqual(UpdateStep.sequence(release: true, fromXcode: false), [.download, .verify, .install, .restart])
        XCTAssertEqual(UpdateStep.sequence(release: false, fromXcode: false), [.fetch, .merge, .generate, .build, .install, .restart])
        XCTAssertEqual(UpdateStep.sequence(release: false, fromXcode: true), [.fetch, .merge, .generate])
        let commit = String(repeating: "ab12", count: 10)
        XCTAssertEqual(UpdateReceipt(from: "x", to: commit, changes: [], installedAt: Date()).shortTarget, "ab12ab1")
        XCTAssertEqual(UpdateReceipt(from: "0.2.0", to: "0.3.0-beta.1", changes: [], installedAt: Date()).shortTarget, "0.3.0-beta.1")
    }

    #if canImport(CryptoKit)
    /// RFC 8032, test 1: CryptoKit checks a standard Ed25519 signature (what scripts/sign-update.swift makes).
    func testEd25519VerifierAcceptsTheRFCVector() {
        func hex(_ text: String) -> Data { Data(stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! }) }
        let publicKey = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let signature = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        XCTAssertTrue(Ed25519Verifier().isValid(signature: signature, of: Data(), publicKey: publicKey))
        XCTAssertFalse(Ed25519Verifier().isValid(signature: signature, of: Data([0]), publicKey: publicKey))
    }
    #endif
}
