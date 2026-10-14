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
enum NookSound {
    case attention, done, error

    @MainActor
    static func play(_ sound: NookSound) {
        guard AppSettings.shared.sounds else { return }
        let name: String
        switch sound {
        case .attention: name = "Ping"
        case .done: name = "Glass"
        case .error: name = "Basso"
        }
        guard let effect = NSSound(named: NSSound.Name(name)) else { return }
        effect.volume = 0.35
        effect.play()
    }
}
