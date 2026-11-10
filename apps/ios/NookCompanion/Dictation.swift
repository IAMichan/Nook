import AVFoundation
import Speech
import SwiftUI

/// Dictation in a composer (docs/COMPANION.md, "Dictation"): the microphone next to Send. It listens on the iPhone itself
/// (`requiresOnDeviceRecognition`) for every language the phone can recognize on the device, in the language of your
/// choice among your own (`DictationLanguages`); what is heard goes into the field as you speak, for you to read and
/// send. Nothing is sent by speaking. Audio never goes to the Mac: the companion's frames carry text, and the phone
/// recognizes speech on its own faster than it could send it.
@MainActor
final class Dictation: ObservableObject {
    enum State: Equatable { case idle, listening, denied, unavailable }

    @Published private(set) var state: State = .idle
    /// The language it listens in, and the ones it offers (your languages the phone can recognize).
    private static let savedKey = "nook.companion.dictationLanguage"
    @Published private(set) var language: String?
    @Published private(set) var languages: [String] = []

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var base = ""

    init() {
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        languages = DictationLanguages.offered(preferred: Locale.preferredLanguages, supported: supported)
        language = DictationLanguages.pick(saved: UserDefaults.standard.string(forKey: Self.savedKey), offered: languages)
    }

    /// Whether this language is recognized on the iPhone itself; otherwise Apple's dictation service hears it.
    static func onDevice(_ language: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language))?.supportsOnDeviceRecognition ?? false
    }

    func choose(_ language: String) {
        UserDefaults.standard.set(language, forKey: Self.savedKey)
        self.language = language
    }

    func toggle(text: Binding<String>) {
        if state == .listening { stop() } else { Task { await start(text: text) } }
    }

    private func start(text: Binding<String>) async {
        guard let language, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            state = .unavailable
            return
        }
        guard await Self.authorized() else {
            state = .denied
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .unavailable
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Self.context
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        base = text.wrappedValue
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish()
            state = .unavailable
            return
        }
        state = .listening
        Haptics.tap()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                if let heard { text.wrappedValue = DictationText.merge(base: self.base, heard: heard) }
                if done { self.stop() }
            }
        }
    }

    /// The words to expect, as on the Mac (`DictationContext`): the projects the Mac offers and the branches of its
    /// sessions, newest first. The phone has no personal dictionary of its own.
    private static var context: [String] {
        let client = CompanionClient.shared
        let branches = client.sessions.sorted { $0.updated > $1.updated }.compactMap(\.branch)
        return DictationContext.strings(dictionary: [], projects: client.launchOptions?.projects.map(\.name) ?? [],
                                        branches: Array(branches.prefix(40)))
    }

    /// The problem was read: back to rest.
    func dismissProblem() {
        if state == .denied || state == .unavailable { state = .idle }
    }

    /// Stops listening; what was heard stays in the field.
    func stop() {
        guard state == .listening else { return }
        request?.endAudio()
        finish()
        state = .idle
        Haptics.tap()
    }

    private func finish() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.finish()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    static func name(_ language: String) -> String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }
}

/// The microphone next to Send: a tap starts and stops listening; a long press picks the language among yours.
struct DictationButton: View {
    @Binding var text: String
    @StateObject private var dictation = Dictation()

    var body: some View {
        if !dictation.languages.isEmpty {
            Menu {
                Section("Dictation language") {
                    ForEach(dictation.languages, id: \.self) { language in
                        Button { dictation.choose(language) } label: {
                            if language == dictation.language {
                                Label(Dictation.name(language), systemImage: "checkmark")
                            } else {
                                Text(Dictation.name(language))
                            }
                        }
                    }
                }
                if let language = dictation.language, !Dictation.onDevice(language) {
                    Text("This language is heard by Apple's dictation service, not on this iPhone.")
                }
            } label: {
                icon
            } primaryAction: {
                dictation.toggle(text: $text)
            }
            .accessibilityLabel(dictation.state == .listening ? Text("Stop dictation") : Text("Dictate"))
            .onDisappear { dictation.stop() }
            .alert(alertText ?? "", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { dictation.dismissProblem() } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var alertText: String? {
        switch dictation.state {
        case .denied: return String(localized: "Allow the microphone and speech recognition for Nook Companion in Settings to dictate.")
        case .unavailable: return String(localized: "Dictation is not available right now.")
        case .idle, .listening: return nil
        }
    }

    private var icon: some View {
        let listening = dictation.state == .listening
        return ZStack {
            Circle().fill(listening ? Theme.coral.opacity(0.22) : Color.clear)
            Image(icon: listening ? "waveform" : "mic")
                .font(Theme.font(15, .semibold))
                .foregroundStyle(listening ? Theme.coral : Theme.textSecondary)
        }
        .frame(width: 34, height: 34)
        .contentShape(Circle())
    }
}
