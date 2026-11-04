import Foundation

/// Sessions without a project: "No project" in the new-session composer starts the agent in a folder of its own under
/// ~/.nook/scratch (`NookPaths.scratchDirectory`), named after the day and the prompt ("2026-11-04-fix-the-login-a1b2c3").
/// The folder is made when you pick "No project" and gets the prompt's name when the session starts; "Turn into project"
/// later makes it a regular project. Foundation only, tested in `ScratchProjectsTests`.
enum ScratchProjects {
    /// The name's part from a prompt that has no words yet.
    static let untitled = "untitled"

    /// "2026-11-04-fix-the-login-bug-a1b2c3": the day, the prompt's first words, the first six characters of `id`.
    static func folderName(date: Date, prompt: String, id: UUID, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return stamp + "-" + slug(prompt) + "-" + shortID(id)
    }

    /// The prompt's first words as a short lowercase slug, or `untitled` when it has none.
    static func slug(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let made = WorktreeNaming.slug(words, limit: 32)
        // `WorktreeNaming.slug` names an empty text for a branch; a folder says plainly that it has no name yet.
        return words.trimmingCharacters(in: .whitespaces).isEmpty || made == WorktreeNaming.slug("") ? untitled : made
    }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(6)) }

    /// True for a folder Nook made for a session without a project (directly in `root`).
    static func isScratch(_ path: String, root: URL = NookPaths.scratchDirectory) -> Bool {
        guard !path.isEmpty else { return false }
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        return folder.deletingLastPathComponent().path == root.standardizedFileURL.path
    }

    /// Makes a new, empty folder for a session without a project and returns its path.
    static func create(prompt: String, date: Date = Date(), id: UUID = UUID(), root: URL = NookPaths.scratchDirectory,
                       fileManager: FileManager = .default) throws -> String {
        let folder = root.appendingPathComponent(folderName(date: date, prompt: prompt, id: id), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    /// The name the folder should have for `prompt`: the same day and id, the prompt's words; nil when that is its name
    /// already or the folder is not one of Nook's scratch folders.
    static func renamedName(_ path: String, prompt: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        // "yyyy-MM-dd-" before the words, "-xxxxxx" after them.
        guard name.count > 18 else { return nil }
        let day = name.prefix(10)
        let id = name.suffix(6)
        let wanted = day + "-" + slug(prompt) + "-" + id
        return wanted == name ? nil : String(wanted)
    }

    /// Gives a folder made before you typed the prompt the prompt's name, while it is still empty (nothing has started
    /// in it yet). Returns the path to start in: the new one, or the old one when it could not or need not move.
    static func rename(_ path: String, prompt: String, root: URL = NookPaths.scratchDirectory,
                       fileManager: FileManager = .default) -> String {
        guard isScratch(path, root: root), let name = renamedName(path, prompt: prompt),
              (try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty == true else { return path }
        let target = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name).path
        guard !fileManager.fileExists(atPath: target), (try? fileManager.moveItem(atPath: path, toPath: target)) != nil else { return path }
        return target
    }

    /// Removes a scratch folder nothing was started in (you picked "No project", then another folder).
    static func discardIfEmpty(_ path: String, root: URL = NookPaths.scratchDirectory, fileManager: FileManager = .default) {
        guard isScratch(path, root: root), (try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty == true else { return }
        try? fileManager.removeItem(atPath: path)
    }
}
