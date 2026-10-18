import AppKit
import AVFoundation
import NaturalLanguage

/// Speech feedback: reads a response aloud using a macOS voice (on-device, nothing leaves your Mac).
@MainActor
final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()

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
            language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "nl"
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

/// Short system sounds indicating when an agent is waiting for you or has finished.
/// Custom sounds take priority: place `attention`, `done`, or `error` (.wav, .mp3, .aiff, or .m4a) in Nook's Sounds directory.
enum NookSound {
    case attention, done, error

    /// Filename without extension for a custom sound, for example `done.mp3`.
    var fileName: String {
        switch self {
        case .attention: return "attention"
        case .done: return "done"
        case .error: return "error"
        }
    }

    /// Built-in macOS sound if no custom file exists.
    private var systemName: String {
        switch self {
        case .attention: return "Ping"
        case .done: return "Glass"
        case .error: return "Basso"
        }
    }

    /// Custom sounds directory: ~/Library/Application Support/Nook/Sounds.
    static var folder: URL {
        NookPaths.supportDirectory.appendingPathComponent("Sounds", isDirectory: true)
    }

    private static let extensions = ["wav", "mp3", "aiff", "aif", "m4a"]

    /// The custom sound file for this sound, if one has been provided.
    var customFile: URL? {
        let fm = FileManager.default
        for ext in Self.extensions {
            let url = Self.folder.appendingPathComponent(fileName).appendingPathExtension(ext)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Retains the currently playing sound; otherwise NSSound could be deallocated midway.
    @MainActor private static var playing: NSSound?

    @MainActor
    static func play(_ sound: NookSound) {
        guard AppSettings.shared.sounds else { return }
        var effect: NSSound?
        var volume: Float = 0.35
        if let url = sound.customFile, let custom = NSSound(contentsOf: url, byReference: true) {
            effect = custom
            // Custom sound files are usually already at an appropriate volume.
            volume = 0.8
        }
        if effect == nil { effect = NSSound(named: NSSound.Name(sound.systemName)) }
        guard let effect else { return }
        playing?.stop()
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
