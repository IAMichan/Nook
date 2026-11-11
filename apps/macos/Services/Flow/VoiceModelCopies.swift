import Foundation

// Parakeet's Core ML models (≈ 600 MB) are often already on this Mac: another app built on FluidAudio keeps them in
// FluidAudio's own folder, and `huggingface-cli download` (or any Hugging Face client) keeps them in the Hugging Face
// cache. Before downloading, Nook looks there and links a complete copy into its own models folder instead of fetching
// a second one. A link, never a copy: the bytes stay where they are, and removing the models in Nook removes only the
// link. Handy (com.pais.handy) also keeps Parakeet, but as ONNX files that FluidAudio cannot load, so it is not looked at.
// Foundation only, so the lookup is tested with a temporary folder (`VoiceModelCopiesTests`).

enum VoiceModelCopies {
    /// Where the same files may already be, best first: FluidAudio's own folder, then every snapshot of the model's
    /// repository in the Hugging Face caches (`HF_HUB_CACHE`, `HF_HOME`/hub, `XDG_CACHE_HOME`, ~/.cache), newest first.
    /// `repository` is the Hugging Face id ("FluidInference/parakeet-ultra-coreml"), `folder` the name FluidAudio gives
    /// its folder ("parakeet-ultra-coreml").
    static func candidates(repository: String, folder: String, home: URL, applicationSupport: URL,
                           environment: [String: String], fileManager: FileManager = .default) -> [URL] {
        var found = [applicationSupport.appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)]
        let cacheName = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        for hub in hubCaches(home: home, environment: environment) {
            let snapshots = hub.appendingPathComponent(cacheName, isDirectory: true).appendingPathComponent("snapshots", isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: snapshots.path)) ?? []
            let dated = names.filter { !$0.hasPrefix(".") }.map { name -> (URL, Date) in
                let url = snapshots.appendingPathComponent(name, isDirectory: true)
                let date = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                return (url, date)
            }
            found += dated.sorted { $0.1 > $1.1 }.map(\.0)
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The Hugging Face hub caches, in the order the Hugging Face clients pick them.
    static func hubCaches(home: URL, environment: [String: String]) -> [URL] {
        func folder(_ path: String?) -> URL? {
            guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
            let expanded = path.hasPrefix("~/") ? home.path + path.dropFirst() : path
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return [folder(environment["HF_HUB_CACHE"]) ?? folder(environment["HUGGINGFACE_HUB_CACHE"]),
                folder(environment["HF_HOME"])?.appendingPathComponent("hub", isDirectory: true),
                folder(environment["XDG_CACHE_HOME"])?.appendingPathComponent("huggingface/hub", isDirectory: true),
                home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)].compactMap { $0 }
    }

    /// Links the first complete copy among `candidates` into `destination` and returns it; nil when none is complete.
    ///
    /// `isComplete` is the check that decides whether models are installed (FluidAudio's `AsrModels.modelsExist`, which
    /// expects the folder under its own name). Each candidate is linked under that name in a staging folder next to
    /// `destination`, checked there, and only then moved into place, so an incomplete copy never replaces anything, and
    /// a destination that is already complete is left alone. A Hugging Face snapshot holds links into the cache's blobs;
    /// a missing blob makes the check fail like a missing file.
    @discardableResult
    static func link(from candidates: [URL], to destination: URL, isComplete: (URL) -> Bool,
                     fileManager: FileManager = .default) -> URL? {
        guard !isComplete(destination) else { return nil }
        let parent = destination.deletingLastPathComponent()
        let ownPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  candidate.resolvingSymlinksInPath().standardizedFileURL.path != ownPath else { continue }
            let staging = parent.appendingPathComponent(".link-" + UUID().uuidString.prefix(8), isDirectory: true)
            defer { try? fileManager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(at: staged, withDestinationURL: candidate)
            } catch { continue }
            guard isComplete(staged) else { continue }
            // What was there was incomplete (an interrupted download, a link whose files are gone): it makes way.
            if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil || fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            do {
                try fileManager.moveItem(at: staged, to: destination)
            } catch { continue }
            return candidate
        }
        return nil
    }

    /// Where Nook's models folder points when it is a link to another app's copy; nil for Nook's own download.
    static func linkedFrom(_ destination: URL, fileManager: FileManager = .default) -> URL? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: destination.path) else { return nil }
        return URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
    }
}
