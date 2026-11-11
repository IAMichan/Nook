import XCTest

final class VoiceModelCopiesTests: XCTestCase {
    private let repository = "FluidInference/parakeet-ultra-coreml"
    private let folder = "parakeet-ultra-coreml"
    private let required = ["Preprocessor.mlmodelc/model.mil", "Encoder.mlmodelc/model.mil", "parakeet_vocab.json"]
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-copies-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    private var support: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    private var destination: URL { support.appendingPathComponent("Nook/Models", isDirectory: true).appendingPathComponent(folder, isDirectory: true) }

    /// Like FluidAudio's `modelsExist`: every required file under the folder named `folder`.
    private func complete(_ url: URL) -> Bool {
        url.lastPathComponent == folder && required.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private func write(_ files: [String], in directory: URL) throws {
        for file in files {
            let url = directory.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private func snapshot(_ revision: String, in hub: URL) -> URL {
        hub.appendingPathComponent("models--FluidInference--parakeet-ultra-coreml/snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    private func candidates(_ environment: [String: String] = [:]) -> [URL] {
        VoiceModelCopies.candidates(repository: repository, folder: folder, home: home, applicationSupport: support, environment: environment)
    }

    func testLooksInFluidAudioFirstThenTheHuggingFaceCaches() {
        let found = candidates(["HF_HOME": root.appendingPathComponent("hf").path]).map(\.path)
        XCTAssertEqual(found.first, support.appendingPathComponent("FluidAudio/Models/parakeet-ultra-coreml").path)
        XCTAssertEqual(VoiceModelCopies.hubCaches(home: home, environment: ["HF_HOME": "~/hf", "HF_HUB_CACHE": "/cache/hub"]).map(\.path),
                       ["/cache/hub", home.path + "/hf/hub", home.path + "/.cache/huggingface/hub"])
    }

    func testCompleteHuggingFaceSnapshotIsLinkedInsteadOfDownloaded() throws {
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        let source = snapshot("abc123", in: hub)
        try write(required, in: source)
        XCTAssertEqual(candidates().last?.path, source.path)

        let linked = VoiceModelCopies.link(from: candidates(), to: destination, isComplete: complete)
        XCTAssertEqual(linked?.path, source.path)
        XCTAssertTrue(complete(destination))
        XCTAssertEqual(VoiceModelCopies.linkedFrom(destination)?.path, source.path)
        // Nothing staged is left behind next to it.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, [folder])
        // Removing Nook's models removes the link, never the other copy.
        try FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(required[0]).path))
    }

    func testIncompleteCopiesAreSkipped() throws {
        let fluid = support.appendingPathComponent("FluidAudio/Models", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        try write(Array(required.dropLast()), in: fluid)
        let hub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
        try write(required, in: snapshot("full", in: hub))
        let linked = VoiceModelCopies.link(from: candidates(), to: destination, isComplete: complete)
        XCTAssertEqual(linked?.lastPathComponent, "full", "the half copy in FluidAudio's folder is passed over")
    }

    func testNothingCompleteLeavesTheDestinationAlone() throws {
        try write(["partial.bin"], in: destination)
        XCTAssertNil(VoiceModelCopies.link(from: candidates(), to: destination, isComplete: complete))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("partial.bin").path))
    }

    func testAnIncompleteDownloadMakesWayForACompleteCopy() throws {
        try write(["partial.bin"], in: destination)
        let fluid = support.appendingPathComponent("FluidAudio/Models", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        try write(required, in: fluid)
        XCTAssertEqual(VoiceModelCopies.link(from: candidates(), to: destination, isComplete: complete)?.path, fluid.path)
        XCTAssertTrue(complete(destination))
    }

    func testOwnCompleteCopyIsKept() throws {
        try write(required, in: destination)
        let fluid = support.appendingPathComponent("FluidAudio/Models", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        try write(required, in: fluid)
        XCTAssertNil(VoiceModelCopies.link(from: candidates(), to: destination, isComplete: complete))
        XCTAssertNil(VoiceModelCopies.linkedFrom(destination), "Nook's own download stays a folder of its own")
    }
}
