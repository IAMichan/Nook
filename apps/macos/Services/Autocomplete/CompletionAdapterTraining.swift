import Foundation
import MLX

/// Trains the personal adapter (see `CompletionAdapter`) from Settings: downloads the MLX build of the autocomplete model
/// once, trains (`CompletionAdapterTrainer`) and keeps the adapter, sealed, only when it predicts the writing kept apart
/// better than the model alone did.
@MainActor
final class CompletionAdapterTraining: ObservableObject {
    static let shared = CompletionAdapterTraining()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case preparing
        case training(step: Int, of: Int)
        case saving
        /// Trained and kept.
        case done(CompletionAdapterInfo)
        /// Trained, but it did not predict the user's writing better: nothing changed.
        case noBetter
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .downloading, .preparing, .training, .saving: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase = Phase.idle
    private var task: Task<Void, Never>?

    /// Starts a training for the GGUF model `file` on `examples`. Does nothing while one runs.
    func start(model file: URL, size: Int64, base: CompletionAdapterBase.Base, examples: [CompletionAdapter.Example]) {
        guard !phase.isRunning else { return }
        phase = .preparing
        task = Task { [weak self] in
            do {
                let report: @Sendable (Phase) -> Void = { update in
                    Task { @MainActor in
                        guard let self, self.phase.isRunning else { return }
                        self.phase = update
                    }
                }
                let directory = try await ModelDownload.fetch(base.repository) { report(.downloading($0)) }
                try Task.checkCancellation()
                let result = try await CompletionAdapterTrainer.train(modelDirectory: directory, architecture: base.architecture,
                                                                      examples: examples) { progress in
                    switch progress {
                    case .preparing: report(.preparing)
                    case .step(let step, let of): report(.training(step: step, of: of))
                    }
                }
                try Task.checkCancellation()
                guard result.lossAfter < result.lossBefore else {
                    Log.autocomplete.notice("personal adapter not better (\(result.lossBefore) → \(result.lossAfter)); not kept")
                    self?.phase = .noBetter
                    return
                }
                self?.phase = .saving
                let info = CompletionAdapterInfo(modelFile: file.lastPathComponent, modelSize: size, repository: base.repository,
                                                 date: Date(), examples: examples.count, steps: result.steps,
                                                 lossBefore: result.lossBefore, lossAfter: result.lossAfter)
                try AutocompleteStore.shared.saveAdapter(result.gguf, info: info)
                Log.autocomplete.notice("personal adapter kept (\(result.lossBefore) → \(result.lossAfter), \(examples.count) examples)")
                self?.phase = .done(info)
                AutocompleteController.shared.refresh()
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                Log.autocomplete.error("personal adapter training failed: \(error.localizedDescription, privacy: .public)")
                self?.phase = .failed(error.localizedDescription)
            }
            MLX.Memory.clearCache()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if phase.isRunning { phase = .idle }
    }

    /// Forgets a finished result (back to the start screen).
    func reset() { if !phase.isRunning { phase = .idle } }
}
