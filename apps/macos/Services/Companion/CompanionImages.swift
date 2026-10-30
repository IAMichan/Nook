import Foundation

/// Pictures that come with a message or a new session from the iPhone companion (`CompanionRequest.images`). They are
/// checked (JPEGs, within `CompanionImage.maxBytes`, at most `maxCount`), saved in Nook's own images folder as the
/// composer saves a pasted picture, and handed to the agent as paths below the words, which agents read from disk.
enum CompanionImages {
    /// The words with the pictures' paths under them; the words alone without pictures; nil when a picture is not one
    /// the phone may send (too many, too big, not a JPEG) or could not be saved.
    static func attach(_ images: [CompanionImage]?, to text: String) -> String? {
        guard let images, !images.isEmpty else { return text }
        guard images.count <= CompanionImage.maxCount else { return nil }
        var paths: [String] = []
        for image in images {
            guard let data = image.data, let url = save(data) else { return nil }
            paths.append(url.path)
        }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (words.isEmpty ? "" : words + "\n\n") + paths.joined(separator: "\n")
    }

    /// Saves one picture where the composer keeps pictures for agents, readable by you only.
    private static func save(_ data: Data) -> URL? {
        let folder = NookPaths.supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("phone-" + UUID().uuidString.prefix(8).lowercased() + ".jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
