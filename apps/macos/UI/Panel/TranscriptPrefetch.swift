import Foundation

/// Reads a transcript off the main thread ahead of time and keeps its conversation in `TranscriptCache`, so a session
/// you are about to open (the row above or below the open one, the row the pointer rests on) shows its conversation in
/// its first frame instead of an empty panel until the file is read.
@MainActor
enum TranscriptPrefetch {
    /// The paths being read now: warming the same path twice starts one read.
    private static var reading: Set<String> = []

    /// Reads the transcript at `path` in the background unless its conversation is already kept or being read.
    /// The read also fills `AgentTranscript`'s own cache, so the open's fresh read only parses what was added since.
    static func warm(path: String) {
        guard !path.isEmpty, TranscriptCache.messages(path) == nil, !reading.contains(path) else { return }
        reading.insert(path)
        Task { @MainActor in
            let messages = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
            reading.remove(path)
            // A conversation that opened meanwhile stored a read of its own: never replace it with this one.
            guard TranscriptCache.messages(path) == nil else { return }
            TranscriptCache.store(messages, path)
        }
    }
}
