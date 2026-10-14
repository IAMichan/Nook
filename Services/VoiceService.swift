import Foundation
import AVFoundation
import Speech

/// Listens only when requested (hotkey or microphone button). Recognition runs on-device whenever possible.
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
        onPartial = nil
        onFinish = nil
    }
}
