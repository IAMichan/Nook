import Foundation

/// Downloads a built-in model from Hugging Face into Nook's own folder, with progress per byte.
///
/// The Hugging Face library downloads through `URLSession.download(for:delegate:)`, whose task delegate never hears about
/// written bytes: a file only counts once it is complete. A model is a few shards of several GB that download at the same
/// time, so the bar stood at 0% for many minutes and then jumped to 100%. Here every file is a plain download task on a
/// session with a delegate, which does report every chunk, so the bar moves with what is really on disk.
enum ModelDownload {
    /// The files MLX needs: the weights, the configuration and the tokenizer (the same set the MLX loader asks for).
    static func isNeeded(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".safetensors") || lower.hasSuffix(".json") || lower.hasSuffix(".jinja")
    }

    /// Where a model lives once Nook downloaded it itself: Application Support/Nook/Models/<org>--<name>.
    static func directory(for id: String) -> URL {
        NookPaths.supportDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    private static let completeMarker = ".complete"

    /// The Hub's file list could not be read or understood: the library's own download is the way out then.
    struct ListingUnavailable: Error {
        var reason: String
    }

    /// Whether an older version of Nook already put this model in the Hugging Face cache (the library loads it from there).
    static func isInHubCache(_ id: String) -> Bool {
        let env = ProcessInfo.processInfo.environment
        let hub = env["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? env["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        let snapshots = hub.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        return !entries.isEmpty
    }

    /// The folder of a model that was downloaded in full; nil when it is not there (or an older install keeps it in the
    /// Hugging Face cache).
    static func completedDirectory(for id: String) -> URL? {
        let dir = directory(for: id)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(completeMarker).path) ? dir : nil
    }

    struct File: Equatable, Sendable {
        var path: String
        var size: Int64
    }

    /// The files of a model and their sizes, from the Hub's file list.
    static func files(of id: String) async throws -> [File] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(id)/tree/main?recursive=true") else {
            throw ListingUnavailable(reason: "invalid model id \(id)")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw ListingUnavailable(reason: "file list answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try parseFiles(data)
    }

    static func parseFiles(_ data: Data) throws -> [File] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ListingUnavailable(reason: "unexpected file list")
        }
        return entries.compactMap { entry in
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String, isNeeded(path) else { return nil }
            let lfs = (entry["lfs"] as? [String: Any])?["size"] as? NSNumber
            let size = lfs ?? (entry["size"] as? NSNumber)
            return File(path: path, size: size?.int64Value ?? 0)
        }
    }

    /// Downloads every file Nook does not have yet (a file of the right size from an interrupted try stays), a few at a
    /// time, and returns the model's folder. `progress` gets the fraction of all bytes, several times a second.
    static func fetch(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dir = directory(for: id)
        let listing = try await files(of: id)
        guard listing.contains(where: { $0.path.lowercased().hasSuffix(".safetensors") }) else {
            throw ListingUnavailable(reason: "no weights listed")
        }
        let total = max(listing.reduce(Int64(0)) { $0 + $1.size }, 1)
        let counter = ByteCounter(total: total, report: progress)
        var missing: [(index: Int, file: File)] = []
        for (index, file) in listing.enumerated() {
            let target = dir.appendingPathComponent(file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
            if let size, file.size > 0, size == file.size {
                counter.set(index, bytes: file.size)
            } else {
                missing.append((index, file))
            }
        }
        counter.flush()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = missing[...]
            // Four at a time: about as fast as the library, without a long tail of half-finished shards.
            for _ in 0..<min(4, queue.count) {
                let next = queue.removeFirst()
                group.addTask { try await download(id: id, file: next.file, to: dir, index: next.index, counter: counter) }
            }
            while try await group.next() != nil {
                guard let next = queue.popFirst() else { continue }
                group.addTask { try await download(id: id, file: next.file, to: dir, index: next.index, counter: counter) }
            }
        }
        counter.flush()
        FileManager.default.createFile(atPath: dir.appendingPathComponent(completeMarker).path, contents: Data())
        return dir
    }

    private static func download(id: String, file: File, to dir: URL, index: Int, counter: ByteCounter) async throws {
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
        guard let url = URL(string: "https://huggingface.co/\(id)/resolve/main/\(encoded)") else {
            throw NookError("Invalid file in \(id): \(file.path)")
        }
        let target = dir.appendingPathComponent(file.path)
        let delegate = FileDownload(destination: target) { written in counter.set(index, bytes: written) }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        counter.set(index, bytes: file.size > 0 ? file.size : counter.bytes(index))
    }
}

/// Adds up the bytes of all files and reports the fraction at most ten times a second, so the main thread is not flooded.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var perFile: [Int: Int64] = [:]
    private var lastReport = Date.distantPast
    private let total: Int64
    private let report: @Sendable (Double) -> Void

    init(total: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func bytes(_ index: Int) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return perFile[index] ?? 0
    }

    func set(_ index: Int, bytes: Int64) {
        lock.lock()
        perFile[index] = bytes
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 0.1 else { lock.unlock(); return }
        lastReport = now
        let fraction = fractionLocked()
        lock.unlock()
        report(fraction)
    }

    func flush() {
        lock.lock()
        let fraction = fractionLocked()
        lock.unlock()
        report(fraction)
    }

    private func fractionLocked() -> Double {
        min(1, Double(perFile.values.reduce(0, +)) / Double(total))
    }
}

/// One file: reports written bytes, moves the finished file into place and resumes the waiting download.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onBytes: @Sendable (Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns: move it now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            failure = NookError("Download failed: Hugging Face answered \(status).")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error = error ?? failure {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
