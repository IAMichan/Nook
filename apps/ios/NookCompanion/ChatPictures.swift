import SwiftUI
import UIKit

/// The chats' own pictures on the phone (`CompanionFeature.avatars`): asked from the Mac once per picture, by the version
/// the inbox names (`InboxChatDigest.avatar`), kept in memory and in the app's caches folder, and asked again only when
/// the version changes. A chat without one shows its initials, as before.
@MainActor
final class ChatPictures: ObservableObject {
    static let shared = ChatPictures()

    /// The decoded pictures by chat id, with the version each was made for.
    @Published private(set) var images: [String: UIImage] = [:]
    private var versions: [String: String] = [:]
    /// Chats asked for right now, or that could not be read lately (left alone for a while).
    private var asking: Set<String> = []
    private var failed: [String: Date] = [:]

    private let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("ChatPictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// The picture of this chat, when the phone has the version the inbox names.
    func image(for chat: InboxChatDigest) -> UIImage? {
        guard let version = chat.avatar, versions[chat.id] == version else { return nil }
        return images[chat.id]
    }

    /// Takes in the inbox as it is now: pictures on disk come in at once, the missing ones are asked from the Mac in small
    /// batches (`ChatAvatar.batch`), the newest chats first.
    func update(_ chats: [InboxChatDigest], client: CompanionClient) {
        var missing: [InboxChatDigest] = []
        for chat in chats {
            guard let version = chat.avatar else { continue }
            if versions[chat.id] == version { continue }
            if let image = UIImage(contentsOfFile: file(chat.id, version).path) {
                store(image, chat: chat.id, version: version)
            } else if !asking.contains(chat.id), failed[chat.id].map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                missing.append(chat)
            }
        }
        guard !missing.isEmpty else { return }
        let wanted = missing.prefix(48).map(\.id)
        asking.formUnion(wanted)
        Task {
            var start = 0
            while start < wanted.count {
                let batch = Array(wanted[start..<min(start + ChatAvatar.batch, wanted.count)])
                start += batch.count
                let pictures = await client.loadAvatars(batch)
                let got = Set(pictures.map(\.chat))
                for picture in pictures {
                    guard let data = Data(base64Encoded: picture.jpeg), let image = UIImage(data: data) else { continue }
                    try? data.write(to: file(picture.chat, picture.version), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    store(image, chat: picture.chat, version: picture.version)
                }
                for id in batch where !got.contains(id) { failed[id] = Date() }
                asking.subtract(batch)
            }
        }
    }

    private func store(_ image: UIImage, chat: String, version: String) {
        // Bounded like the Mac's list of pictures: far more than a phone lists.
        if images.count > 600 {
            images.removeAll(keepingCapacity: true)
            versions.removeAll(keepingCapacity: true)
        }
        versions[chat] = version
        images[chat] = image
    }

    private func file(_ chat: String, _ version: String) -> URL {
        let name = PureSHA256.hash(Data(chat.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(name)-\(version).jpg")
    }
}

extension CompanionClient {
    /// The pictures of these chats from the Mac (`CompanionOp.avatars`); none from a Mac that does not send them.
    func loadAvatars(_ chats: [String]) async -> [ChatAvatar] {
        guard can(CompanionFeature.avatars), phase == .connected, !chats.isEmpty else { return [] }
        return await perform(CompanionRequest(op: .avatars, items: chats), quiet: true)?.avatars ?? []
    }
}
