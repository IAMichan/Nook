import AVFoundation
import Combine
@preconcurrency import FluidAudio
import os

/// NVIDIA's Parakeet speech recognition and a speaker diarizer, run on the Mac's Neural Engine by FluidAudio (Apache-2.0):
/// more accurate than the Mac's own recognizer, 25 languages, entirely offline. The models (≈ 650 MB) are downloaded once
/// from Hugging Face when you click Download (Settings › Voice & sound), kept in Application Support/Nook/Models, and
/// then everything runs on this Mac. Used for Flow dictation and the Notetaker, which then also tells the other people
/// in a call apart.
///
/// Adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).
@MainActor
final class Parakeet: ObservableObject {
    static let shared = Parakeet()

    /// Parakeet Ultra: v3's 25 languages, more accurate, same speed.
    nonisolated static let version: AsrModelVersion = .ultra

    enum State: Equatable {
        /// Intel Mac: the models need the Neural Engine of Apple silicon.
        case unsupported
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing
    /// Use Parakeet when it is installed (Settings); off: the Mac's own recognizer.
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "parakeetEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "parakeetEnabled") }
    }

    private var loading: Task<AsrManager, Error>?
    /// The loaded models stay in memory (about a gigabyte, on the Neural Engine) only while they are used: released after
    /// `idleSeconds` without a transcription, and at once when macOS runs low on memory. Loading again takes a second or
    /// two, and dictation starts it while you speak (`FlowDictation.begin`).
    private var idleTask: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private static let idleSeconds: UInt64 = 10 * 60

    private init() {
        refresh()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.unload() } }
        source.resume()
        pressureSource = source
    }

    /// Drops the loaded models; a transcription still running keeps its own reference and finishes.
    func unload() {
        idleTask?.cancel()
        idleTask = nil
        loading = nil
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Nook's own copy of the models, so removing them never touches another app's.
    nonisolated static var modelsRoot: URL {
        NookPaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static var asrDirectory: URL {
        modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }

    nonisolated static var installed: Bool {
        AsrModels.modelsExist(at: asrDirectory, version: version)
    }

    var isReady: Bool { state == .ready }
    /// Ready and switched on: Flow and the Notetaker use it.
    var inUse: Bool { isReady && enabled }

    func refresh() {
        if !Self.isSupported { state = .unsupported; return }
        if case .downloading = state { return }
        state = Self.installed ? .ready : .missing
    }

    /// Downloads Parakeet and the diarizer, then loads Parakeet so the first dictation is quick.
    func download() {
        guard Self.isSupported else { return }
        if case .downloading = state { return }
        state = .downloading(0)
        Task { @MainActor in
            do {
                try await Self.fetchModels { fraction in
                    Task { @MainActor in
                        if case .downloading(let shown) = Parakeet.shared.state, fraction > shown {
                            Parakeet.shared.state = .downloading(fraction)
                        }
                    }
                }
                state = .ready
                Log.app.info("Parakeet: models downloaded")
                _ = try? await manager()
            } catch {
                Log.app.error("Parakeet: download failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated private static func fetchModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        _ = try await AsrModels.download(to: asrDirectory, version: version, progressHandler: { update in
            progress(min(0.92, update.fractionCompleted * 0.92))
        })
        try await prepareDiarizer()
        progress(1)
    }

    /// Downloads (once) and loads the Notetaker's speaker diarizer.
    nonisolated static func prepareDiarizer() async throws {
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels(directory: modelsRoot)
    }

    /// Removes the models from this Mac.
    func remove() {
        loading?.cancel()
        loading = nil
        try? FileManager.default.removeItem(at: Self.modelsRoot)
        refresh()
    }

    /// Loads Parakeet once; later calls get the same instance.
    func manager() async throws -> AsrManager {
        scheduleUnload()
        if let loading { return try await loading.value }
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.load(from: Self.asrDirectory, version: Self.version)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return asr
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    /// Loads the model in the background when dictation will use it, so the first one is quick.
    func preload() {
        guard inUse, loading == nil else { return }
        Task { @MainActor in _ = try? await manager() }
    }

    /// 16 kHz mono samples → text.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeWithTimings(samples).text
    }

    func transcribeWithTimings(_ samples: [Float]) async throws -> ASRResult {
        var audio = samples
        // Parakeet wants at least a second, and a little silence at the end keeps the last word.
        audio.append(contentsOf: [Float](repeating: 0, count: max(4_800, 16_000 - audio.count)))
        let asr = try await manager()
        var decoder = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(audio, decoderState: &decoder)
    }

    /// Words with their times in a stretch of 16 kHz audio that starts `offset` seconds into the recording.
    func words(_ samples: [Float], offset: Double) async -> [TimedWord] {
        guard let result = try? await transcribeWithTimings(samples) else { return [] }
        return buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedWord(text: $0.word, start: offset + $0.startTime, end: offset + $0.endTime)
        }
    }

    /// Who speaks when in 16 kHz audio kept in memory (the other people of a call).
    nonisolated static func diarize(_ samples: [Float]) async throws -> [SpeakerTurn] {
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels(directory: modelsRoot)
        let result = try await diarizer.process(audio: samples)
        return result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), embedding: $0.embedding)
        }
    }
}

/// Flow dictation with Parakeet: the microphone is recorded while the key is held, then Parakeet writes it all at once
/// (a few hundred milliseconds for a minute of speech).
final class ParakeetDictation: @unchecked Sendable {
    @MainActor private(set) var isRecording = false
    /// Loudness 0…1 for the pill.
    var onLevel: (@MainActor (Double) -> Void)?

    private let engine = AVAudioEngine()
    private let samples = OSAllocatedUnfairLock(initialState: [Float]())

    @MainActor func start() async {
        guard !isRecording, await AVAudioApplication.requestRecordPermission() else { return }
        samples.withLock { $0.removeAll(keepingCapacity: true) }
        guard Self.startEngine(engine, into: samples, level: onLevel) else { return }
        isRecording = true
    }

    /// Stops the microphone and returns the words.
    @MainActor func finish() async -> String {
        guard isRecording else { return "" }
        stopEngine()
        let audio = samples.withLock { $0 }
        do {
            return try await Parakeet.shared.transcribe(audio)
        } catch {
            Log.app.error("Parakeet: dictation failed: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    /// Stops without words (Esc, another key).
    @MainActor func stop() {
        guard isRecording else { return }
        stopEngine()
        samples.withLock { $0.removeAll() }
    }

    @MainActor private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    nonisolated private static func startEngine(_ engine: AVAudioEngine, into samples: OSAllocatedUnfairLock<[Float]>,
                                                level: (@MainActor (Double) -> Void)?) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = Resampler16k(from: format) else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let out = resampler.convert(buffer)
            if !out.isEmpty { samples.withLock { $0.append(contentsOf: out) } }
            if let level {
                let rms = LiveChannel.rms(out[...])
                let value = min(1, max(0, Double(20 * log10(max(rms, 1e-6)) + 55) / 45))
                Task { @MainActor in level(value) }
            }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }
}
