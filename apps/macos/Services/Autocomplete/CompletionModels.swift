import Foundation

/// A GGUF model file on this Mac that autocompletion can run.
struct CompletionModelFile: Identifiable, Equatable {
    /// found: another app or tool on this Mac downloaded it; nook: Nook's own models folder; custom: picked by hand.
    enum Source: Equatable { case found, nook, custom }

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

/// Finds GGUF language models already on this Mac (downloaded by other apps and tools), so Nook can complete text with a
/// file that is there instead of fetching a second copy. Nothing is copied or changed: a file is only read, in place.
///
/// It looks in the places such apps keep their models: Application Support, Caches, LM Studio's folder and the Hugging Face
/// and llama.cpp caches. Other apps' sandbox containers are left alone (macOS asks permission for those). Vision projectors,
/// embedding models and files too small to be a language model are skipped; the user can always pick a file by hand.
enum CompletionModelLocator {
    /// Model types that cannot write text.
    static let notTextModels: Set<String> = ["bert", "nomic-bert", "jina-bert-v2", "t5encoder", "clip", "wavtokenizer-dec"]

    static func foundModels(home: URL = FileManager.default.homeDirectoryForCurrentUser, minimumBytes: Int64 = 50_000_000) -> [CompletionModelFile] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let nook = library.appendingPathComponent("Application Support/Nook", isDirectory: true).standardizedFileURL.path
        let roots: [(URL, Int)] = [
            (library.appendingPathComponent("Application Support", isDirectory: true), 6),
            (library.appendingPathComponent("Caches", isDirectory: true), 5),
            (home.appendingPathComponent(".lmstudio/models", isDirectory: true), 4),
            (home.appendingPathComponent(".cache/lm-studio/models", isDirectory: true), 4),
            (home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true), 5),
            (home.appendingPathComponent(".cache/llama.cpp", isDirectory: true), 2),
        ]
        var seen = Set<String>()
        let files = roots.flatMap { ggufFiles(in: $0.0, maxDepth: $0.1) }
            .filter { !$0.standardizedFileURL.path.hasPrefix(nook) }
            .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
        return files.compactMap { model(at: $0, source: .found) }
            .filter { $0.bytes >= minimumBytes && !notTextModels.contains($0.info?.architecture ?? "") }
            .sorted { $0.modified > $1.modified }
    }

    /// The model file to use: the one the user picked if it is still there, otherwise the newest one found on this Mac, then
    /// one Nook downloaded itself.
    static func resolve(storedPath: String, candidates: [CompletionModelFile]) -> CompletionModelFile? {
        if !storedPath.isEmpty {
            if let known = candidates.first(where: { $0.url.path == storedPath }) { return known }
            return model(at: URL(fileURLWithPath: storedPath), source: .custom)
        }
        return candidates.first { $0.source == .found } ?? candidates.first
    }

    /// The GGUF files Nook downloaded or the user dropped in its models folder.
    static func nookModels(in folder: URL) -> [CompletionModelFile] {
        ggufFiles(in: folder, maxDepth: 1).compactMap { model(at: $0, source: .nook) }.sorted { $0.modified > $1.modified }
    }

    /// A readable GGUF file, or nil.
    static func model(at url: URL, source: CompletionModelFile.Source) -> CompletionModelFile? {
        // The Hugging Face cache keeps its files as links to blobs: read what the link points at.
        let file = url.resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let info = GGUFReader.read(file) else { return nil }
        return CompletionModelFile(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                                   info: info, source: source)
    }

    /// Every `.gguf` file under `root` (not the vision projectors that sit next to some models), a few levels deep.
    static func ggufFiles(in root: URL, maxDepth: Int = 6, limit: Int = 200) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isModelFile(root) ? [root] : [] }
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { return [] }
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
}

/// What autocomplete runs on: a GGUF file through llama.cpp, or the model Nook's brain already downloaded (MLX).
enum CompletionSource: Equatable {
    case gguf(CompletionModelFile)
    case brain(id: String, title: String)

    /// Stored in the settings as the model choice: a file path, or "brain:" and the model's id.
    var identity: String {
        switch self {
        case .gguf(let file): return file.url.path
        case .brain(let id, _): return Self.brainPrefix + id
        }
    }

    var title: String {
        switch self {
        case .gguf(let file): return file.title
        case .brain(_, let title): return title
        }
    }

    static let brainPrefix = "brain:"

    /// The source to use.
    /// - Parameters:
    ///   - stored: the setting: empty for automatic, a GGUF path, or "brain:<id>".
    ///   - files: GGUF files found on this Mac and in Nook's folder, best first.
    ///   - brainModels: the brain's installed models (id, title).
    ///   - preferredBrain: the model the brain uses now, when it is one of them.
    /// Automatic takes a GGUF model found on this Mac, then one in Nook's folder, then the brain's model: every Mac with a
    /// local brain can complete without downloading anything.
    static func resolve(stored: String, files: [CompletionModelFile], brainModels: [(id: String, title: String)],
                        preferredBrain: String?) -> CompletionSource? {
        if stored.hasPrefix(brainPrefix) {
            let id = String(stored.dropFirst(brainPrefix.count))
            return brainModels.first { $0.id == id }.map { .brain(id: $0.id, title: $0.title) }
        }
        if !stored.isEmpty { return CompletionModelLocator.resolve(storedPath: stored, candidates: files).map { .gguf($0) } }
        if let file = CompletionModelLocator.resolve(storedPath: "", candidates: files) { return .gguf(file) }
        let brain = brainModels.first { $0.id == preferredBrain } ?? brainModels.first
        return brain.map { .brain(id: $0.id, title: $0.title) }
    }
}

/// A model Nook can download for autocomplete when none is on this Mac yet. Base (not chat) models: plain continuation is
/// what inline completion needs. The list follows Typist's catalog (MIT, © 2026 Brody Salvucci).
struct CompletionCatalogModel: Identifiable, Equatable {
    var name: String
    var fileName: String
    var repository: String
    var sizeGB: Double
    /// Below this much memory the model is not recommended.
    var minimumMemoryGB: Int
    /// Key of the one-line note (i18n).
    var noteKey: String

    /// A link of its own, for a model you paste instead of picking from the list.
    var link: URL? = nil

    var id: String { fileName }
    var url: URL { link ?? URL(string: "https://huggingface.co/\(repository)/resolve/main/\(fileName)")! }

    /// A model from a pasted link to a `.gguf` file: a Hugging Face page of the file ("…/blob/main/x.gguf", turned into its
    /// download link) or any https link ending in `.gguf`. Nil for anything else.
    static func custom(from text: String) -> CompletionCatalogModel? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        guard let last = parts.last, last.lowercased().hasSuffix(".gguf"), !last.lowercased().contains("mmproj") else { return nil }
        if host == "huggingface.co" || host == "hf.co" {
            // owner/repo/(blob|resolve)/revision/path…
            guard parts.count >= 5, ["blob", "resolve"].contains(parts[2]) else { return nil }
            parts[2] = "resolve"
            components.host = "huggingface.co"
            components.path = "/" + parts.joined(separator: "/")
            components.query = nil
        }
        guard let url = components.url else { return nil }
        let name = String(last.dropLast(5))
        return CompletionCatalogModel(name: name, fileName: last, repository: "", sizeGB: 0, minimumMemoryGB: 0, noteKey: "", link: url)
    }

    static let catalog: [CompletionCatalogModel] = [
        CompletionCatalogModel(name: "Qwen3 0.6B Base", fileName: "Qwen3-0.6B-Base.i1-Q4_K_M.gguf",
                               repository: "mradermacher/Qwen3-0.6B-Base-i1-GGUF", sizeGB: 0.4, minimumMemoryGB: 8, noteKey: "autocomplete.note.fastest"),
        CompletionCatalogModel(name: "Qwen3 1.7B Base", fileName: "Qwen3-1.7B-Base.i1-Q4_K_M.gguf",
                               repository: "mradermacher/Qwen3-1.7B-Base-i1-GGUF", sizeGB: 1.1, minimumMemoryGB: 8, noteKey: "autocomplete.note.balanced"),
        CompletionCatalogModel(name: "Gemma 3 1B", fileName: "gemma-3-1b-pt.i1-Q4_K_M.gguf",
                               repository: "mradermacher/gemma-3-1b-pt-i1-GGUF", sizeGB: 0.8, minimumMemoryGB: 8, noteKey: "autocomplete.note.gemmaSmall"),
        CompletionCatalogModel(name: "Qwen3 4B Base", fileName: "Qwen3-4B-Base.i1-Q4_K_M.gguf",
                               repository: "mradermacher/Qwen3-4B-Base-i1-GGUF", sizeGB: 2.5, minimumMemoryGB: 16, noteKey: "autocomplete.note.better"),
        CompletionCatalogModel(name: "Gemma 3 4B", fileName: "gemma-3-4b-pt.i1-Q4_K_M.gguf",
                               repository: "mradermacher/gemma-3-4b-pt-i1-GGUF", sizeGB: 2.5, minimumMemoryGB: 16, noteKey: "autocomplete.note.gemmaLarge"),
        CompletionCatalogModel(name: "Qwen3 8B Base", fileName: "Qwen3-8B-Base.i1-Q4_K_M.gguf",
                               repository: "mradermacher/Qwen3-8B-Base-i1-GGUF", sizeGB: 5.0, minimumMemoryGB: 24, noteKey: "autocomplete.note.best"),
    ]

    /// The best model this Mac runs comfortably. Gemma, because it writes Dutch (Nook's first language) better than Qwen.
    static func recommended(memoryGB: Int) -> CompletionCatalogModel {
        memoryGB >= 16 ? catalog[4] : catalog[2]
    }
}
