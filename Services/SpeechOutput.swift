import AppKit
import AVFoundation
import NaturalLanguage

/// Nook praat terug: leest een antwoord voor met een stem van macOS (op je Mac, niets gaat het internet op).
@MainActor
final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: String(clean.prefix(600)))
        utterance.voice = AVSpeechSynthesisVoice(language: Self.voiceLanguage(for: language, text: clean))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

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

/// Korte systeemgeluiden, zodat je hoort dat een agent op je wacht of klaar is.
/// Eigen geluiden gaan voor: leg `attention`, `done` of `error` (.wav, .mp3, .aiff of .m4a) in de map Sounds van Nook.
enum NookSound {
    case attention, done, error

    /// Bestandsnaam zonder extensie voor een eigen geluid, bijvoorbeeld `done.mp3`.
    var fileName: String {
        switch self {
        case .attention: return "attention"
        case .done: return "done"
        case .error: return "error"
        }
    }

    /// Ingebouwd geluid van macOS als er geen eigen bestand is.
    private var systemName: String {
        switch self {
        case .attention: return "Ping"
        case .done: return "Glass"
        case .error: return "Basso"
        }
    }

    /// Map met eigen geluiden: ~/Library/Application Support/Nook/Sounds.
    static var folder: URL {
        NookPaths.supportDirectory.appendingPathComponent("Sounds", isDirectory: true)
    }

    private static let extensions = ["wav", "mp3", "aiff", "aif", "m4a"]

    /// Het eigen geluidsbestand voor dit geluid, als je er een hebt neergelegd.
    var customFile: URL? {
        let fm = FileManager.default
        for ext in Self.extensions {
            let url = Self.folder.appendingPathComponent(fileName).appendingPathExtension(ext)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Houdt het spelende geluid vast; anders kan NSSound halverwege worden opgeruimd.
    @MainActor private static var playing: NSSound?

    @MainActor
    static func play(_ sound: NookSound) {
        guard AppSettings.shared.sounds else { return }
        var effect: NSSound?
        var volume: Float = 0.35
        if let url = sound.customFile, let custom = NSSound(contentsOf: url, byReference: true) {
            effect = custom
            // Eigen bestanden staan meestal al op het goede volume.
            volume = 0.8
        }
        if effect == nil { effect = NSSound(named: NSSound.Name(sound.systemName)) }
        guard let effect else { return }
        playing?.stop()
        effect.volume = volume
        effect.play()
        playing = effect
    }

    /// Maakt de map met eigen geluiden aan (als die er nog niet is) en laat hem zien in de Finder.
    @MainActor
    static func openFolder() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Openen in plaats van selecteren: dan kun je er meteen bestanden in slepen.
        NSWorkspace.shared.open(folder)
    }
}
