import Foundation
import AVFoundation
import Speech

/// Listens only when requested (hotkey or microphone button). Recognition runs on-device whenever possible.
@MainActor
final class VoiceService: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""

    /// One recognizer per language, made when it is first needed.
    private var recognizers: [String: SFSpeechRecognizer] = [:]
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onPartial: ((String) -> Void)?
    private var onFinish: ((String) -> Void)?

    private var hasTap = false

    static var permissionsGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func requestPermissions() async -> Bool {
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        let speechOK: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return micOK && speechOK
    }

    /// The language to listen in: the language Nook answers in, or with "auto" the language of Nook's interface. The Mac's
    /// own region wins when it speaks that language (nl-BE, en-GB), so accents are recognized better.
    static func locale(answerLanguage: String, appLanguage: String, current: Locale = .current) -> Locale {
        let code = answerLanguage == "auto" ? appLanguage : answerLanguage
        if current.language.languageCode?.identifier == code, let region = current.region?.identifier {
            let local = Locale(identifier: "\(code)-\(region)")
            if SFSpeechRecognizer.supportedLocales().contains(where: { $0.identifier.replacingOccurrences(of: "_", with: "-") == local.identifier }) {
                return local
            }
        }
        let regions = ["nl": "nl-NL", "en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES"]
        return Locale(identifier: regions[code] ?? "nl-NL")
    }

    private func recognizer(for locale: Locale) -> SFSpeechRecognizer? {
        if let known = recognizers[locale.identifier] { return known }
        let made = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
        recognizers[locale.identifier] = made
        return made
    }

    func start(locale: Locale = Locale(identifier: "nl-NL"), onPartial: @escaping (String) -> Void, onFinish: @escaping (String) -> Void) throws {
        guard !isListening else { return }
        guard let recognizer = self.recognizer(for: locale), recognizer.isAvailable else {
            throw NookError("Speech recognition is currently unavailable.")
        }
        self.onPartial = onPartial
        self.onFinish = onFinish
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

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
        isListening = true
        armSilenceTimer(seconds: 6)   // generous time to start speaking

        task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, failed in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let text {
                    self.transcript = text
                    self.onPartial?(text)
                    if isFinal {
                        self.finishNow()
                        return
                    }
                    self.armSilenceTimer(seconds: 1.8)
                }
                if failed {
                    self.finishNow()
                }
            }
        }
    }

    // These two are nonisolated because audio and recognition threads invoke them.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            VoiceLevel.shared.measure(buffer)
        }
    }

    private nonisolated static func startTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    /// Stops listening and delivers the recognized transcript.
    func finishNow() {
        guard isListening else { return }
        let text = transcript
        let callback = onFinish
        teardown()
        callback?(text)
    }

    /// Stops listening without delivering anything.
    func cancel() {
        guard isListening else { return }
        teardown()
    }

    private func armSilenceTimer(seconds: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishNow() }
        }
    }

    private func teardown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
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
        isListening = false
        VoiceLevel.shared.reset()
        onPartial = nil
        onFinish = nil
    }
}

/// How loud you speak while Nook listens, 0…1, so the orb can move with your voice.
/// Written on the audio thread, read by the orb every frame.
final class VoiceLevel: @unchecked Sendable {
    static let shared = VoiceLevel()

    private let lock = NSLock()
    private var level: Float = 0

    var current: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(level)
    }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        // Speech sits roughly between -50 dB (soft) and -10 dB (loud).
        let decibels = 20 * log10(max(rms, 0.000_001))
        let value = min(max((decibels + 50) / 40, 0), 1)
        lock.lock()
        level = value
        lock.unlock()
    }

    func reset() {
        lock.lock()
        level = 0
        lock.unlock()
    }
}
