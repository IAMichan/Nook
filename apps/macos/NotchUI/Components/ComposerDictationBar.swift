import SwiftUI
import Combine

/// The composer's microphone (`SessionComposer.dictating()`): you speak, the words land at the caret, and the box
/// stays read-only until they are in. Send while it listens finishes the recording and sends once the words have landed;
/// Escape or the cross throws the recording away and leaves the draft as it was. The rules are `ComposerDictation`; this
/// talks to the speech service, which the whole app shares.
@MainActor
final class ComposerDictator: ObservableObject {
    @Published private(set) var state = ComposerDictation()
    /// What Send pressed while dictating does once the words are in.
    private var pendingSend: (() -> Void)?
    /// Watches the speech service, so a recording another part of Nook took over does not leave the box locked.
    private var watch: AnyCancellable?

    var isActive: Bool { state.isActive }

    /// Starts listening on top of `body`, the words going in at `selection` (UTF-16 in `body`, nil: at the end). `apply`
    /// gets the box's words as they come in, and the caret after them.
    func start(body: String, selection: Range<Int>? = nil, folder: String? = nil, apply: @escaping (String, Int) -> Void) {
        guard !state.isActive else { return }
        let app = AppModel.shared
        let context = Self.context(app: app, folder: folder)
        Task { @MainActor in
            guard await app.voice.requestPermissions(), !app.voice.isListening,
                  self.state.begin(body: body, selection: selection) else { return }
            app.wake.stop()
            app.speech.stop()
            let partial: (String) -> Void = { [weak self] spoken in
                guard let self, self.state.phase == .listening else { return }
                apply(self.state.text(with: spoken), self.state.caret(with: spoken))
            }
            let finished: (String) -> Void = { [weak self] spoken in
                guard let self, self.state.isActive else { return }
                let landed = self.state.land(spoken)
                apply(landed.text, landed.caret)
                let send = self.pendingSend
                self.pendingSend = nil
                app.updateWakeWord()
                // The box takes the words first; the message goes on the next turn of the run loop.
                if landed.send, let send { DispatchQueue.main.async { send() } }
            }
            if app.settings.language == "auto" {
                app.voice.startMultilingual(contextualStrings: context, onPartial: partial, onFinish: finished)
            } else {
                do {
                    try app.voice.start(
                        locale: VoiceService.locale(answerLanguage: app.settings.language, appLanguage: app.settings.appLanguage.rawValue),
                        contextualStrings: context, onPartial: partial, onFinish: finished)
                } catch {
                    _ = self.state.discard()
                    app.updateWakeWord()
                    return
                }
            }
            self.watchVoice()
        }
    }

    /// The words the recognizer expects: your personal dictionary (Settings › Flow), then the composer's own project and
    /// its branch, then your other projects and the branches of your sessions (`DictationContext`).
    private static func context(app: AppModel, folder: String?) -> [String] {
        let workspace = app.workspace
        let runs = workspace.runs.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }
        let own = folder.map(WorkspacePathPolicy.normalize)
        let ownRuns = runs.filter { own != nil && WorkspacePathPolicy.normalize($0.workingDirectory) == own }
        let folders = [folder].compactMap { $0 } + workspace.settings.favoriteProjects + workspace.settings.recentProjects
        let branches = (ownRuns + runs).compactMap(\.branch)
        return DictationContext.strings(dictionary: FlowStore.shared.words,
                                        projects: folders.map { ($0 as NSString).lastPathComponent },
                                        branches: Array(branches.prefix(40)))
    }

    /// Stops listening and keeps the words.
    func finish() {
        if state.finish() { AppModel.shared.voice.finishNow() }
    }

    /// Send pressed while dictating: finish and run `send` once the words are in. False when nothing records, so the
    /// caller sends as usual.
    func send(_ send: @escaping () -> Void) -> Bool {
        guard state.isActive else { return false }
        pendingSend = send
        if state.requestSend() { AppModel.shared.voice.finishNow() }
        return true
    }

    /// Throws the recording away; `restore` gets the box's words from before it started. False when nothing recorded.
    @discardableResult
    func discard(restore: (String) -> Void) -> Bool {
        let listening = state.phase == .listening
        guard let before = state.discard() else { return false }
        pendingSend = nil
        watch = nil
        if listening { AppModel.shared.voice.cancel() }
        restore(before)
        AppModel.shared.updateWakeWord()
        return true
    }

    /// When the service stops without telling this recording (another part of Nook took the microphone), the box is let
    /// go after a moment; the words that came in so far stay.
    private func watchVoice() {
        watch = AppModel.shared.voice.$isListening
            .removeDuplicates()
            .filter { !$0 }
            .debounce(for: .seconds(4), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.state.isActive, !AppModel.shared.voice.isListening else { return }
                _ = self.state.discard()
                self.pendingSend = nil
                self.watch = nil
            }
    }
}

/// The microphone next to send: starts dictating, or finishes while it listens.
struct ComposerDictationButton: View {
    @ObservedObject var dictator: ComposerDictator
    let toggle: () -> Void

    var body: some View {
        let label = dictator.isActive ? tr("compose.dictate.finish") : tr("compose.dictate.start")
        NookIconButton(systemName: dictator.isActive ? "mic.fill" : "mic", label: label, size: 30, inComposer: true, action: toggle)
    }
}

/// Above the text while dictating: that the microphone listens (or that the message goes once the words are in), how
/// loud you speak, and the buttons to throw the recording away or finish it.
struct ComposerDictationBar: View {
    @ObservedObject var dictator: ComposerDictator
    let tint: Color
    let discard: () -> Void
    let finish: () -> Void

    /// The height of each of the 12 bars for a voice level; out of `body`, where the CI runner's compiler gave up
    /// type-checking the arithmetic in reasonable time.
    private static func barLevels(_ level: Double) -> [Double] {
        (0..<12).map { (index: Int) -> Double in
            let shape: Double = 0.4 + 0.6 * abs(sin(Double(index) * 1.7))
            return 0.2 + 0.8 * level * shape
        }
    }

    var body: some View {
        if dictator.isActive {
            HStack(spacing: NookTheme.Spacing.sm) {
                Circle()
                    .fill(NookTheme.coral)
                    .frame(width: 7, height: 7)
                Text(status)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                // Set straight on layers from the measured voice level: no SwiftUI update per frame.
                LayerLevelBars(count: 12, barWidth: 2, spacing: 2, color: tint,
                               fps: dictator.state.phase == .listening ? 20 : 0) {
                    Self.barLevels(VoiceLevel.shared.current)
                }
                .frame(width: 46, height: 12)
                Spacer(minLength: NookTheme.Spacing.sm)
                NookIconButton(systemName: "xmark", label: tr("compose.dictate.discard"), size: 22, action: discard)
                if dictator.state.phase == .listening {
                    NookIconButton(systemName: "checkmark", label: tr("compose.dictate.finish"), size: 22, action: finish)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(status)
            .transition(.opacity)
        }
    }

    private var status: String {
        if dictator.state.sendsWhenDone { return tr("compose.dictate.sending") }
        return dictator.state.phase == .listening ? tr("compose.dictate.listening") : tr("compose.dictate.finishing")
    }
}
