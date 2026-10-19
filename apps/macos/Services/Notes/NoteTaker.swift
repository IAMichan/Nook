import AppKit
import AVFoundation
import Combine
import Speech
import os

/// The Notetaker: records a call (your microphone, and what the Mac plays for the other people), writes the transcript
/// while you talk, and afterwards the summary, key points and to-dos with your own brain (on this Mac by default).
///
/// The audio never touches the disk: each stretch is transcribed on the Mac as soon as it ends on a pause
/// and then forgotten. With Parakeet the others' side also stays in memory during the call, only so the diarizer can
/// tell the people apart at the end. Notes are kept as JSON in Application Support/Nook/Notes, and Nook can search them in the chat
/// ("wat spraken we af met Lisa?"). No bot joins the call: tell the other people that you take notes.
@MainActor
final class NoteTaker: ObservableObject {
    static let shared = NoteTaker()

    /// Newest first.
    @Published private(set) var notes: [Note] = []
    /// The note being recorded, with its live lines.
    @Published private(set) var current: Note?
    @Published private(set) var level: Float = 0
    @Published private(set) var problem: String?

    /// Writes the summary: system prompt, transcript → the brain's reply, or nil.
    var summarize: ((String, String) async -> String?)?
    /// A note is ready (or failed): Nook shows it in the chat.
    var onFinished: ((Note) -> Void)?
    /// The language to transcribe in.
    var locale: () -> Locale = { Locale(identifier: "nl-NL") }

    private let mic = MicCapture()
    private let system = SystemAudioTap()
    private let mine = LiveChannel()
    private let others = LiveChannel()
    private var myWords: [TimedWord] = []
    private var theirWords: [TimedWord] = []
    private var loop: Task<Void, Never>?
    /// With Parakeet: the others' side, kept in memory only so the diarizer can tell the people apart.
    private var othersFile: SideBuffer?
    private var transcribing = 0
    private var starting = false

    nonisolated static var folder: URL { NookPaths.supportDirectory.appendingPathComponent("Notes", isDirectory: true) }

    var isRecording: Bool { current != nil }

    /// Notes deleted before the saved ones finished loading, so they do not come back with them.
    private var deletedEarly: Set<UUID>? = []

    private init() {
        // Every note holds its whole transcript: read them off the main thread so launching Nook does not wait for it.
        Task.detached(priority: .utility) { [weak self] in
            let loaded = Self.loadAll()
            await self?.finishLoading(loaded)
        }
    }

    private func finishLoading(_ loaded: [Note]) {
        let known = Set(notes.map(\.id)).union(deletedEarly ?? [])
        deletedEarly = nil
        notes = (notes + loaded.filter { !known.contains($0.id) }).sorted { $0.start > $1.start }
    }

    // MARK: Recording

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard current == nil, !starting else { return }
        starting = true
        defer { starting = false }
        problem = nil
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = tr("notes.problem.mic")
            return
        }
        let speechOK = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speechOK else {
            problem = tr("notes.problem.speech")
            return
        }
        myWords = []
        theirWords = []
        _ = mine.takeChunk(force: true)
        _ = others.takeChunk(force: true)
        let mineChannel = mine, othersChannel = others
        othersFile = Parakeet.shared.inUse ? SideBuffer() : nil
        let writer = othersFile
        guard mic.start(sink: { mineChannel.append($0) }) else {
            othersFile = nil
            problem = tr("notes.problem.mic")
            return
        }
        do {
            try system.start(sink: { samples in
                othersChannel.append(samples)
                writer?.append(samples)
            })
        } catch {
            // Without the Mac's sound (permission refused): only your side, and the room through the microphone.
            Log.app.info("Notetaker: no system audio: \(error.localizedDescription, privacy: .public)")
        }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        current = Note(title: tr("notes.untitled"), start: Date(), app: app)
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick(force: false)
            }
        }
    }

    func stop() {
        guard var note = current else { return }
        loop?.cancel()
        loop = nil
        mic.stop()
        system.stop()
        tick(force: true)
        note.end = Date()
        note.status = .processing
        current = nil
        level = 0
        Task { @MainActor [weak self] in
            // The last stretches are still being transcribed.
            var waited = 0
            while let self, self.transcribing > 0, waited < 60 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 1
            }
            await self?.finish(note)
        }
    }

    private func tick(force: Bool) {
        level = max(mine.level, others.level)
        if let chunk = mine.takeChunk(force: force) { transcribe(chunk, mine: true) }
        if let chunk = others.takeChunk(force: force) { transcribe(chunk, mine: false) }
    }

    private func transcribe(_ chunk: (start: Double, samples: [Float]), mine: Bool) {
        transcribing += 1
        let locale = locale()
        let parakeet = Parakeet.shared.inUse
        Task { @MainActor [weak self] in
            let words = parakeet ? await Parakeet.shared.words(chunk.samples, offset: chunk.start)
                : await Self.recognize(chunk.samples, offset: chunk.start, locale: locale)
            guard let self else { return }
            self.transcribing -= 1
            if mine { self.myWords += words } else { self.theirWords += words }
            self.refreshLive()
        }
    }

    private func refreshLive() {
        guard var note = current else { return }
        let built = NoteBuilder.build(mine: myWords.sorted { $0.start < $1.start }, others: theirWords.sorted { $0.start < $1.start },
                                      meName: tr("notes.me"), othersName: tr("notes.others"))
        note.speakers = built.speakers
        note.lines = built.lines
        current = note
    }

    /// One stretch of 16 kHz audio → its words with their times, on this Mac.
    nonisolated private static func recognize(_ samples: [Float], offset: Double, locale: Locale) async -> [TimedWord] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable,
              let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.append(buffer)
        request.endAudio()
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let task = recognizer.recognitionTask(with: request) { result, error in
                guard let result, result.isFinal || error != nil else {
                    if error != nil, once.claim() { continuation.resume(returning: []) }
                    return
                }
                guard once.claim() else { return }
                let segments = result.bestTranscription.segments.map { (text: $0.substring, start: $0.timestamp, duration: $0.duration) }
                continuation.resume(returning: NoteBuilder.words(segments, offset: offset))
            }
            // A recognizer that never answers does not hold the note up.
            DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
                if once.claim() { task.cancel(); continuation.resume(returning: []) }
            }
        }
    }

    // MARK: Notes

    private func finish(_ recorded: Note) async {
        var note = recorded
        let mine = myWords.sorted { $0.start < $1.start }, theirs = theirWords.sorted { $0.start < $1.start }
        var built = NoteBuilder.build(mine: mine, others: theirs, meName: tr("notes.me"), othersName: tr("notes.others"))
        // With Parakeet: who of the others said what ("Persoon 2", "Persoon 3"). The temporary recording goes right after.
        if let buffer = othersFile {
            othersFile = nil
            let audio = buffer.take()
            if !theirs.isEmpty, audio.count > 16_000, let turns = try? await Parakeet.diarize(audio), !turns.isEmpty {
                built = NoteBuilder.build(mine: mine, others: theirs, turns: NoteBuilder.mergingFragments(turns),
                                          meName: tr("notes.me"), personName: { tr("notes.person", $0) })
            }
        }
        note.speakers = built.speakers
        note.lines = built.lines
        guard !note.lines.isEmpty else {
            note.status = .failed
            note.error = tr("notes.problem.empty")
            onFinished?(note)
            return
        }
        save(note)
        if let summarize, let reply = await summarize(NoteBuilder.summaryInstructions,
                                                      "<transcript>\n\(NoteBuilder.plainTranscript(note).prefix(200_000))\n</transcript>") {
            if let parsed = NoteBuilder.parseSummary(reply) {
                if let title = parsed.title { note.title = title }
                note.summary = parsed.summary
                note.keyPoints = parsed.keyPoints
                note.todos = parsed.todos
            } else {
                note.summary = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        note.status = .ready
        save(note)
        onFinished?(note)
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        deletedEarly?.insert(id)
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id.uuidString).json"))
    }

    func markdown(_ note: Note) -> String {
        NoteBuilder.markdown(note, labels: .init(summary: tr("notes.md.summary"), keyPoints: tr("notes.md.keyPoints"),
                                                 todos: tr("notes.md.todos"), transcript: tr("notes.md.transcript")))
    }

    private func save(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note } else { notes.insert(note, at: 0) }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try SafeStorage.write(try encoder.encode(note), to: Self.folder.appendingPathComponent("\(note.id.uuidString).json"))
        } catch {
            Log.storage.error("Notetaker: note not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func loadAll() -> [Note] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { SafeStorage.load(Note.self, from: $0, decoder: decoder).value }
            .sorted { $0.start > $1.start }
    }
}

/// Resumes a continuation once, whichever callback comes first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The others' side of a call in memory (at most 90 minutes, about 350 MB), only so the diarizer can tell the people
/// apart at the end; never written to disk, gone as soon as the note is made.
private final class SideBuffer: @unchecked Sendable {
    private let samples = OSAllocatedUnfairLock(initialState: [Float]())
    private let limit = 16_000 * 60 * 90

    /// From the audio thread.
    func append(_ new: [Float]) {
        samples.withLock { all in
            guard all.count + new.count <= limit else { return }
            all.append(contentsOf: new)
        }
    }

    func take() -> [Float] {
        samples.withLock { all in
            let out = all
            all = []
            return out
        }
    }
}
