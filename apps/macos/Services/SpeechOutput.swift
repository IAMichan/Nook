import AppKit
import AVFoundation
import NaturalLanguage

/// Speech feedback: reads a response aloud using a macOS voice (on-device, nothing leaves your Mac).
@MainActor
final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private let mouth = SpeechMouth()

    init() {
        synthesizer.delegate = mouth
    }

    func speak(_ text: String, language: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: String(SpokenText.plain(clean).prefix(1_200)))
        utterance.voice = Self.bestVoice(for: Self.voiceLanguage(for: language, text: clean))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    /// Adds a sentence after what is being said (the answer read while it is written).
    func enqueue(_ text: String, language: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: String(clean.prefix(1_200)))
        utterance.voice = Self.bestVoice(for: Self.voiceLanguage(for: language, text: clean))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// The best installed voice for a language: Premium before Enhanced before the compact default, then the same region
    /// (nl-NL before nl-BE). Novelty voices and the user's Personal Voice are never used. Remembered per language;
    /// a voice downloaded later is picked up after a restart of Nook.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let known = chosen[language] { return known }
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix(prefix)
                && !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int) {
            let quality: Int
            switch voice.quality {
            case .premium: quality = 2
            case .enhanced: quality = 1
            default: quality = 0
            }
            return (quality, voice.language == language ? 1 : 0)
        }
        let best = candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: language)
        chosen[language] = best
        return best
    }

    private static var chosen: [String: AVSpeechSynthesisVoice] = [:]

    private static func voiceLanguage(for code: String, text: String) -> String {
        var language = code
        if language == "auto" {
            language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        }
        switch language {
        case "en": return "en-US"
        case "de": return "de-DE"
        case "fr": return "fr-FR"
        case "es": return "es-ES"
        default: return "nl-NL"
        }
    }
}

/// Tells Nook which word is being read aloud, so his mouth can move along with it.
private final class SpeechMouth: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let range = Range(characterRange, in: utterance.speechString) else { return }
        let word = String(utterance.speechString[range])
        Task { @MainActor in NookPresence.shared.speaking(word: word) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in NookPresence.shared.stoppedSpeaking() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in NookPresence.shared.stoppedSpeaking() }
    }
}

/// Short system sounds indicating when an agent is waiting for you or has finished.
/// Custom sounds take priority: place `attention`, `done`, or `error` (.wav, .mp3, .aiff, or .m4a) in Nook's Sounds directory.
enum NookSound: String, CaseIterable, Identifiable {
    /// In the order Settings › Sound & voice lists them.
    case done, permission, attention, error

    var id: String { rawValue }

    /// Filename without extension for a custom sound, for example `done.mp3`.
    var fileName: String { rawValue }

    /// The Settings label of the moment this sound is for.
    var titleKey: String { "settings.sound.event.\(rawValue)" }

    /// Built-in macOS sound when nothing else was chosen and no custom file exists.
    var defaultSystemName: String {
        switch self {
        case .attention: return "Ping"
        case .permission: return "Hero"
        case .done: return "Glass"
        case .error: return "Basso"
        }
    }

    /// What plays for this moment (Settings › Sound & voice). Stored as a string in `AppSettings.soundChoices`:
    /// empty for the default, `none`, `file` for the custom file, or the name of a macOS sound.
    enum Choice: Hashable {
        case standard, none, file
        case system(String)

        init(stored: String?) {
            switch stored ?? "" {
            case "": self = .standard
            case "none": self = .none
            case "file": self = .file
            case let name: self = .system(name)
            }
        }

        var stored: String {
            switch self {
            case .standard: return ""
            case .none: return "none"
            case .file: return "file"
            case .system(let name): return name
            }
        }
    }

    /// The macOS sounds to choose from (/System/Library/Sounds), sorted by name.
    static let systemSounds: [String] = {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
        let fallback = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                        "Sosumi", "Submarine", "Tink"]
        return (names.isEmpty ? fallback : names).sorted()
    }()

    /// Custom sounds directory: ~/Library/Application Support/Nook/Sounds.
    static var folder: URL {
        NookPaths.supportDirectory.appendingPathComponent("Sounds", isDirectory: true)
    }

    private static let extensions = ["wav", "mp3", "aiff", "aif", "m4a"]

    /// The custom sound file for this sound, if one has been provided. A permission request without a `permission`
    /// file of its own uses `attention`, as it did before it had a sound of its own.
    var customFile: URL? {
        let fm = FileManager.default
        let names = self == .permission ? [fileName, NookSound.attention.fileName] : [fileName]
        for name in names {
            for ext in Self.extensions {
                let url = Self.folder.appendingPathComponent(name).appendingPathExtension(ext)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// The sound this moment makes with `choice`, at its volume; nil for silence.
    @MainActor
    private func effect(for choice: Choice) -> (sound: NSSound, volume: Float)? {
        // Custom sound files are usually already at an appropriate volume.
        func file() -> (NSSound, Float)? {
            customFile.flatMap { NSSound(contentsOf: $0, byReference: true) }.map { ($0, 0.8) }
        }
        func system(_ name: String) -> (NSSound, Float)? {
            NSSound(named: NSSound.Name(name)).map { ($0, 0.35) }
        }
        switch choice {
        case .none: return nil
        case .file: return file() ?? system(defaultSystemName)
        case .system(let name): return system(name) ?? system(defaultSystemName)
        case .standard: return file() ?? system(defaultSystemName)
        }
    }

    /// Retains the currently playing sound; otherwise NSSound could be deallocated midway.
    @MainActor private static var playing: NSSound?
    /// Silent while you share your screen or sit in a meeting, when you chose so (`AppModel+Quiet`).
    @MainActor static var muted = false

    @MainActor
    static func play(_ sound: NookSound) {
        guard AppSettings.shared.sounds, !muted else { return }
        play(sound, choice: Choice(stored: AppSettings.shared.soundChoices[sound.rawValue]))
    }

    /// Plays `sound` as `choice` would, also with sounds off or muted: the preview when you pick one in Settings.
    @MainActor
    static func play(_ sound: NookSound, choice: Choice) {
        playing?.stop()
        playing = nil
        guard let (effect, volume) = sound.effect(for: choice) else { return }
        effect.volume = volume
        effect.play()
        playing = effect
    }

    /// Creates the custom sounds directory (if it does not exist yet) and reveals it in Finder.
    @MainActor
    static func openFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Open instead of select, so files can be dragged directly into it.
        NSWorkspace.shared.open(folder)
    }
}
