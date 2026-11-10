import Foundation

/// The words a recognizer is told to expect (`SFSpeechRecognitionRequest.contextualStrings`), on the Mac and the iPhone:
/// your personal dictionary first, then the names of your projects and branches, so "Nook" and "login-flow" are heard as
/// you write them.
enum DictationContext {
    /// Apple advises to keep the list short; more words slow recognition down without helping it.
    static let limit = 100
    static let maxLength = 60

    /// The dictionary words, then the names (with a spoken variant for `kebab-case`, `snake_case` and `a/b`), each once,
    /// at most `limit`. A branch prefix such as `nook/` is dropped: nobody says it.
    static func strings(dictionary: [String], projects: [String] = [], branches: [String] = []) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= maxLength, out.count < limit, seen.insert(word.lowercased()).inserted else { return }
            out.append(word)
        }
        func addName(_ raw: String) {
            add(raw)
            let spoken = raw.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "/", with: " ")
            if spoken != raw { add(spoken) }
        }
        dictionary.forEach(add)
        projects.forEach(addName)
        for branch in branches {
            let parts = branch.split(separator: "/")
            addName(parts.count > 1 ? parts.dropFirst().joined(separator: "/") : branch)
        }
        return out
    }
}
