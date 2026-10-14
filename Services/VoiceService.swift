import Foundation
import AVFoundation
import Speech

/// Luistert alleen als jij het vraagt (sneltoets of microfoonknop). Waar mogelijk gebeurt de herkenning op je eigen Mac.
@MainActor
final class VoiceService: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
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

    func start(onPartial: @escaping (String) -> Void, onFinish: @escaping (String) -> Void) throws {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw NookError("Spraakherkenning is nu niet beschikbaar.")
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
        armSilenceTimer(seconds: 6)   // ruim de tijd om te beginnen met praten

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

    // Deze twee staan buiten de main actor, omdat de audio- en herkenningsthreads ze aanroepen.
    private nonisolated static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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

    /// Stopt het luisteren en geeft de tekst door.
    func finishNow() {
        guard isListening else { return }
        let text = transcript
        let callback = onFinish
        teardown()
        callback?(text)
    }

    /// Stopt zonder iets door te geven.
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
        onPartial = nil
        onFinish = nil
    }
}
