import SwiftUI
import UIKit

/// The photos in chat messages on the phone (`CompanionOp.inboxMedia`): asked from the Mac when a bubble with one comes
/// into view, a few at a time, by the version the message names (`InboxLine.thumb`), kept in memory and in the caches
/// folder, and asked again only when the version changes.
@MainActor
final class ChatMediaStore: ObservableObject {
    static let shared = ChatMediaStore()

    /// The decoded photos by "chat|line|version".
    @Published private(set) var images: [String: UIImage] = [:]
    /// Wanted and not yet asked, per chat; asked right now; and the ones the Mac could not give lately.
    private var wanted: [String: [(line: String, version: String)]] = [:]
    private var asking: Set<String> = []
    private var failed: [String: Date] = [:]
    private var flushing = false

    private let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("ChatMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// The photo of this message, when the phone has its version.
    func image(chat: String, line: InboxLine) -> UIImage? {
        guard let version = line.thumb else { return nil }
        return images[Self.key(chat, line.id, version)]
    }

    /// A bubble with a photo came into view: from disk at once, else asked from the Mac shortly, with the others that
    /// came into view meanwhile.
    func want(chat: String, line: InboxLine, client: CompanionClient) {
        guard let version = line.thumb else { return }
        let key = Self.key(chat, line.id, version)
        guard images[key] == nil, !asking.contains(key) else { return }
        if let image = UIImage(contentsOfFile: file(key).path) {
            store(image, key: key)
            return
        }
        guard failed[key].map({ Date().timeIntervalSince($0) > 120 }) ?? true else { return }
        asking.insert(key)
        wanted[chat, default: []].append((line.id, version))
        guard !flushing else { return }
        flushing = true
        Task {
            // Bubbles that come into view together go in one request.
            try? await Task.sleep(for: .milliseconds(120))
            await flush(client)
            flushing = false
        }
    }

    private func flush(_ client: CompanionClient) async {
        while let (chat, lines) = wanted.first {
            wanted[chat] = nil
            var start = 0
            while start < lines.count {
                let batch = Array(lines[start..<min(start + InboxMedia.batch, lines.count)])
                start += batch.count
                let got = await client.fetchInboxMedia(chat, lines: batch.map(\.line))
                var arrived: Set<String> = []
                for media in got {
                    let key = Self.key(chat, media.line, media.version)
                    guard let data = Data(base64Encoded: media.jpeg), let image = UIImage(data: data) else { continue }
                    try? data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    store(image, key: key)
                    arrived.insert(key)
                }
                for item in batch {
                    let key = Self.key(chat, item.line, item.version)
                    asking.remove(key)
                    if !arrived.contains(key) { failed[key] = Date() }
                }
            }
        }
    }

    private func store(_ image: UIImage, key: String) {
        // A few dozen photos in memory; the rest stays on disk.
        if images.count > 120 { images.removeAll(keepingCapacity: true) }
        images[key] = image
    }

    private static func key(_ chat: String, _ line: String, _ version: String) -> String { chat + "|" + line + "|" + version }

    private func file(_ key: String) -> URL {
        let name = PureSHA256.hash(Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".jpg")
    }
}
