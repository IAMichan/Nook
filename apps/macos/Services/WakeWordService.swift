import Foundation
import AppKit
import AVFoundation
import Speech

/// Listens in the background for "Hey Nook" and triggers active listening.
/// Disabled by default and requires on-device speech recognition: audio never leaves your Mac.
///
/// Frugal: the microphone only measures loudness until someone speaks (EnergyVAD); speech
/// recognition runs for that stretch only, with the half second before it, and stops in the silence after. Listening
/// pauses while the screen is locked or asleep and in Low Power Mode, and comes back by itself.
@MainActor
final class WakeWordService {
    var onWake: (() -> Void)?
    /// The microphone could not be started after `start()` returned; listening is off again.
    var onError: ((String) -> Void)?
    /// The user turned it on (it may be paused for now).
    private(set) var isRunning = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
    private let audio = WakeAudio()
    private let gate = WakeGate()
    private var task: SFSpeechRecognitionTask?
    private var paused = false
    private var observers: [NSObjectProtocol] = []
    /// Each speech stretch gets an incremented generation; late results of an older one are ignored.
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

    func start() throws {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw NookError("This Mac cannot recognize speech on-device, so wake word remains disabled (audio never leaves your Mac).")
        }
        guard VoiceService.permissionsGranted else {
            throw NookError("Please grant Nook access to microphone and speech recognition first.")
        }
        isRunning = true
        observePause()
        if shouldPause { paused = true } else { listen(reportFailure: true) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        paused = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers = []
        // Wait for the microphone to be released: voice input may start right after.
        teardown(wait: true)
    }

    // MARK: Listening for speech

    /// Starts the microphone off the main thread (see `WakeAudio`).
    private func listen(reportFailure: Bool) {
        audio.start(gate: gate, onEvent: { [weak self] event in
            switch event {
            case .start: Task { @MainActor in self?.speechStarted() }
            case .end: Task { @MainActor in self?.speechEnded() }
            case .none: break
            }
        }, failed: { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in
                guard let self, self.isRunning, !self.paused else { return }
                self.stop()
                if reportFailure { self.onError?(message) }
            }
        })
    }

    /// Someone speaks: recognize this stretch, with the moment before it.
    private func speechStarted() {
        guard isRunning, !paused, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .search
        generation += 1
        let current = generation
        task?.cancel()
        task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, finished in
            Task { @MainActor in
                guard let self, self.isRunning, self.generation == current else { return }
                if let text, Self.matches(text) {
                    self.stop()
                    self.onWake?()
                } else if finished {
                    self.task = nil
                }
            }
        }
        gate.attach(request)
    }

    /// Silence again: the stretch is over; recognition stops.
    private func speechEnded() {
        gate.detach()?.endAudio()
    }

    private func teardown(wait: Bool = false) {
        audio.stop(wait: wait)
        gate.detach()?.endAudio()
        task?.cancel()
        task = nil
    }

    // MARK: Pausing

    private var shouldPause: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func observePause() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pauseNames: [Notification.Name] = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                                               NSWorkspace.sessionDidResignActiveNotification]
        let resumeNames: [Notification.Name] = [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification,
                                                NSWorkspace.sessionDidBecomeActiveNotification]
        for name in pauseNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        }
        for name in resumeNames {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            })
        }
        // Screen locked: macOS posts this distributed notification.
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.shouldPause { self.pause() } else { self.resume() }
            }
        })
    }

    private func pause() {
        guard isRunning, !paused else { return }
        paused = true
        teardown()
    }

    private func resume() {
        guard isRunning, paused, !shouldPause else { return }
        paused = false
        listen(reportFailure: false)
    }

    // MARK: Matching

    static func matches(_ text: String) -> Bool {
        guard let pattern else { return false }
        // Only check the trailing suffix to avoid matching earlier wake words retained in the text.
        let tail = String(text.suffix(40))
        return pattern.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
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

/// The microphone: AVAudioEngine is created, started and stopped on its own serial queue. Starting the audio hardware can
/// take hundreds of milliseconds, and that should hold up neither launching Nook nor waking the screen.
private final class WakeAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nl.imdigital.nook.wakeword.audio", qos: .userInitiated)
    /// Only touched on `queue`.
    private var engine: AVAudioEngine?
    private var hasTap = false

    func start(gate: WakeGate, onEvent: @escaping @Sendable (EnergyVAD.Event) -> Void, failed: @escaping @Sendable (Error) -> Void) {
        queue.async {
            let engine = self.engine ?? AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            if self.hasTap { input.removeTap(onBus: 0) }
            gate.reset()
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                onEvent(gate.consume(buffer))
            }
            self.hasTap = true
            engine.prepare()
            do { try engine.start() } catch { failed(error) }
        }
    }

    func stop(wait: Bool) {
        let work = {
            guard let engine = self.engine else { return }
            if engine.isRunning { engine.stop() }
            if self.hasTap {
                engine.inputNode.removeTap(onBus: 0)
                self.hasTap = false
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }
}

/// The audio thread's side: loudness → voice activity, the last half second kept for the start of a word, and the
/// recognition request the buffers go to while someone speaks.
private final class WakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var vad = EnergyVAD()
    private var rateSet = false
    private var preroll: [AVAudioPCMBuffer] = []
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        vad = EnergyVAD()
        rateSet = false
        preroll = []
        request = nil
    }

    func consume(_ buffer: AVAudioPCMBuffer) -> EnergyVAD.Event {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return .none }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let power = Double(sum / Float(count))
        lock.lock()
        defer { lock.unlock() }
        if !rateSet {
            vad.setFrameRate(buffer.format.sampleRate / Double(count))
            rateSet = true
        }
        let event = vad.feed(power)
        if let request {
            request.append(buffer)
        } else if let copy = Self.copy(buffer) {
            preroll.append(copy)
            let keep = max(1, Int((0.5 * buffer.format.sampleRate / Double(count)).rounded(.up)))
            if preroll.count > keep { preroll.removeFirst(preroll.count - keep) }
        }
        return event
    }

    func attach(_ request: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in preroll { request.append(buffer) }
        preroll = []
        self.request = request
    }

    /// Stops sending buffers; returns the request so it can be ended.
    func detach() -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        let current = request
        request = nil
        vad.reset()
        return current
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let from = buffer.floatChannelData, let to = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            to[channel].update(from: from[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}
