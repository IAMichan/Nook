import Foundation
import AVFoundation
import Speech

/// Listens in the background for "Hey Nook" and triggers active listening.
/// Disabled by default and requires on-device speech recognition: audio never leaves your Mac.
@MainActor
final class WakeWordService {
    var onWake: (() -> Void)?
    private(set) var isRunning = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    /// Each new recognition task receives an incremented generation ID; stale messages are ignored.
    private var generation = 0

    /// "hé nook", "hey nook", "oké nook"… plus common speech recognition approximations.
    private static let pattern = try? NSRegularExpression(
        pattern: #"\b(h[eé]+|hey|hee|hoi|hi|ok[eé]?|okay|oke)[ ,]+(nook|nuk|nok|noek|nouk|look)\b"#,
        options: [.caseInsensitive]
    )

    /// Can this Mac recognize the wake word offline?
    static var supported: Bool {
        SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))?.supportsOnDeviceRecognition ?? false
    }

    private var hasTap = false

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw NookError("This Mac cannot recognize speech on-device, so wake word remains disabled (audio never leaves your Mac).")
        }
        guard VoiceService.permissionsGranted else {
            throw NookError("Please grant Nook access to microphone and speech recognition first.")
        }
        isRunning = true
        try begin(recognizer)
        // A recognition task lasts at most one minute; restart every 50 seconds.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        teardown()
    }

    private func restart() {
        guard isRunning, let recognizer else { return }
        teardown()
        do {
            try begin(recognizer)
        } catch {
            stop()
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .search
        self.request = request
        generation += 1
        let current = generation

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        if hasTap {
            input.removeTap(onBus: 0)
            hasTap = false
        }
        Self.installTap(on: input, format: format, request: request)
        hasTap = true
        engine.prepare()
        try engine.start()

        task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, finished in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == current else { return }
                if let text, Self.matches(text) {
                    self.stop()
                    self.onWake?()
                } else if finished {
                    // Brief delay to prevent tight restart loops on error.
                    self.generation += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.restart()
                }
            }
        }
    }

    private func teardown() {
        if engine.isRunning {
            engine.stop()
        }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    static func matches(_ text: String) -> Bool {
        guard let pattern else { return false }
        // Only check the trailing suffix to avoid matching earlier wake words retained in the text.
        let tail = String(text.suffix(40))
        return pattern.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
    }

    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func startTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }
}
