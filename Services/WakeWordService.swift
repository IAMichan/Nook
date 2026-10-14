import Foundation
import AVFoundation
import Speech

/// Luistert op de achtergrond naar "Hé Nook" en start dan het gewone luisteren.
/// Staat standaard uit en werkt alleen als je Mac spraak zelf kan herkennen: er gaat nooit geluid naar buiten.
@MainActor
final class WakeWordService {
    var onWake: (() -> Void)?
    private(set) var isRunning = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    /// Elke nieuwe herkenningstaak krijgt een nummer; berichten van een oude taak tellen niet meer.
    private var generation = 0

    /// "hé nook", "hey nook", "oké nook"… plus wat de herkenning er vaak van maakt.
    private static let pattern = try? NSRegularExpression(
        pattern: #"\b(h[eé]+|hey|hee|hoi|hi|ok[eé]?|okay|oke)[ ,]+(nook|nuk|nok|noek|nouk|look)\b"#,
        options: [.caseInsensitive]
    )

    /// Kan deze Mac het wekwoord herkennen zonder internet?
    static var supported: Bool {
        SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))?.supportsOnDeviceRecognition ?? false
    }

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw NookError("Deze Mac kan spraak niet zelf herkennen, dus het wekwoord blijft uit (er gaat nooit geluid naar buiten).")
        }
        guard VoiceService.permissionsGranted else {
            throw NookError("Geef Nook eerst toegang tot de microfoon en spraakherkenning.")
        }
        isRunning = true
        try begin(recognizer)
        // Een herkenningstaak duurt hooguit een minuut; daarom elke 50 seconden opnieuw.
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
    }

    func stop() {
        restartTimer?.invalidate()
        restartTimer = nil
        teardown()
        isRunning = false
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
        input.removeTap(onBus: 0)
        Self.installTap(on: input, format: format, request: request)
        engine.prepare()
        try engine.start()

        task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, finished in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == current else { return }
                if let text, Self.matches(text) {
                    self.stop()
                    self.onWake?()
                } else if finished {
                    // Even wachten, zodat een fout niet in een snelle lus blijft herstarten.
                    self.generation += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.restart()
                }
            }
        }
    }

    private func teardown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    static func matches(_ text: String) -> Bool {
        guard let pattern else { return false }
        // Alleen het laatste stukje telt, anders blijft een oude "hé nook" in de tekst hangen.
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
