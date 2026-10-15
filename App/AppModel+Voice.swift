import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Voice: listening, wake word and spoken answers.
extension AppModel {
    // MARK: Voice

    /// Prewarms connection or preloads local model to minimize latency for subsequent queries.
    func warmUp() {
        if settings.useLocal {
            EmbeddedModel.shared.preload(settings.localModel)
        } else {
            brain.prewarm()
        }
    }

    func toggleVoice() {
        if voice.isListening {
            voice.finishNow()
            return
        }
        guard settings.brainReady else {
            presentSetupCard()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await voice.requestPermissions() else {
                viewModel.present(errorCard("Nook mag nog niet luisteren. Zet de microfoon en spraakherkenning aan bij Systeminstellingen › Privacy en beveiliging."))
                return
            }
            warmUp()
            wake.stop()
            speech.stop()
            viewModel.register("listening#done") { [weak self] in self?.voice.finishNow() }
            viewModel.register("listening#cancel") { [weak self] in self?.voice.cancel() }
            viewModel.show(.card(listeningCard("")))
            do {
                try voice.start(
                    onPartial: { [weak self] text in
                        guard let self else { return }
                        self.viewModel.updateCard(self.listeningCard(text))
                    },
                    onFinish: { [weak self] text in self?.voiceFinished(text) }
                )
            } catch {
                viewModel.show(.card(errorCard(error.localizedDescription)))
            }
        }
    }

    func voiceFinished(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            viewModel.dismissCard(id: "listening")
        } else {
            spokenRequest = true
            handleUserText(trimmed)
        }
    }

    func updateWakeWord() {
        guard settings.wakeWord else {
            wake.stop()
            return
        }
        guard !voice.isListening, !wake.isRunning else { return }
        do {
            try wake.start()
        } catch {
            settings.wakeWord = false
            viewModel.present(errorCard(error.localizedDescription))
        }
    }

    func listeningCard(_ text: String) -> NookCard {
        NookCard(
            id: "listening",
            mood: .listen,
            context: "Ik luister, praat gerust",
            title: text.isEmpty ? "Zeg het maar…" : "“\(text)”",
            detail: .waveform,
            primary: CardAction(label: "Klaar", outcome: .callback("listening#done", "")),
            secondary: CardAction(label: "Annuleren", outcome: .callback("listening#cancel", "")),
            contentHeight: 166
        )
    }
}
