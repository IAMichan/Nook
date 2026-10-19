import Foundation

/// A GGUF model file on this Mac that autocompletion can run.
struct CompletionModelFile: Identifiable, Equatable {
    enum Source: Equatable { case cotypist, custom }

    let url: URL
    let bytes: Int64
    let modified: Date
    let info: GGUFInfo?
    let source: Source

    var id: String { url.path }

    /// The model's own name when the file has one, otherwise the file name.
    var title: String {
        if let name = info?.name, !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Finds the language model that Cotypist downloaded, so Nook can complete text with the same file instead of fetching a
/// second copy. Nothing is copied or changed: the file is only read, in place.
///
/// Cotypist is a closed app and does not document where it keeps its models, so this looks for folders named after it
/// (Application Support, Containers, Caches, and the app bundle) and takes every GGUF file inside. A file in another format
/// is not recognised and is skipped; the user can always pick a file by hand.
enum CompletionModelLocator {
    /// Names of folders and apps that belong to Cotypist, compared in lowercase.
    static let needles = ["cotypist"]

    static func cotypistModels(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               applications: [URL] = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities")]) -> [CompletionModelFile] {
        var roots: [URL] = []
        let library = home.appendingPathComponent("Library", isDirectory: true)
        for parent in ["Application Support", "Caches", "Containers", "Group Containers"] {
            roots += children(of: library.appendingPathComponent(parent, isDirectory: true)).filter(matches)
        }
        for folder in applications { roots += children(of: folder).filter(matches) }
        var seen = Set<String>()
        let files = roots.flatMap { ggufFiles(in: $0) }.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return files.compactMap { model(at: $0, source: .cotypist) }
            .sorted { $0.modified > $1.modified }
    }

    /// The model file to use: the one the user picked if it is still there, otherwise the newest one Cotypist has.
    static func resolve(storedPath: String, candidates: [CompletionModelFile]) -> CompletionModelFile? {
        if !storedPath.isEmpty { return model(at: URL(fileURLWithPath: storedPath), source: .custom) }
        return candidates.first
    }

    /// A readable GGUF file, or nil.
    static func model(at url: URL, source: CompletionModelFile.Source) -> CompletionModelFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let info = GGUFReader.read(url) else { return nil }
        return CompletionModelFile(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                                   info: info, source: source)
    }

    /// Every `.gguf` file under `root` (not the vision projectors that sit next to some models), a few levels deep.
    static func ggufFiles(in root: URL, maxDepth: Int = 6, limit: Int = 200) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isModelFile(root) ? [root] : [] }
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if walker.level > maxDepth { walker.skipDescendants(); continue }
            if isModelFile(url) { found.append(url) }
            if found.count >= limit { break }
        }
        return found
    }

    private static func isModelFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gguf" && !url.lastPathComponent.lowercased().contains("mmproj")
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    private static func matches(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return needles.contains { name.contains($0) }
    }
}
