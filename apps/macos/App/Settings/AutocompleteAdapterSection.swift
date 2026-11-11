import SwiftUI

/// Settings › Autocomplete › Style & Context › Personal model: train an adapter on your own writing, on this Mac (see
/// `CompletionAdapter`). Each user trains their own; it never leaves the Mac.
struct AutocompleteAdapterSection: View {
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared
    @ObservedObject private var training = CompletionAdapterTraining.shared
    /// Counted when the page opens and after a setting changes: building the examples reads every chat.
    @State private var examples = 0

    var body: some View {
        Section {
            progress
            if let info = store.adapter, !training.phase.isRunning {
                StatusRow(title: tr("autocomplete.adapter.trained", info.examples),
                          detail: tr("autocomplete.adapter.trainedDetail", info.date.formatted(date: .abbreviated, time: .omitted),
                                     Int((info.improvement * 100).rounded())),
                          state: .done) {
                    ConfirmedButton(symbol: "trash", title: tr("autocomplete.adapter.delete"), question: tr("autocomplete.adapter.deleteQuestion")) {
                        store.forgetAdapter()
                        training.reset()
                        autocomplete.refresh()
                    }
                    .labelled(tr("autocomplete.adapter.delete"))
                    .buttonStyle(.borderless)
                }
                SettingToggle(tr("autocomplete.adapter.use"), detail: tr("autocomplete.adapter.useDetail"), isOn: $store.prefs.personalAdapter)
                    .onChange(of: store.prefs.personalAdapter) { _, _ in autocomplete.refresh() }
            }
            SettingToggle(tr("autocomplete.adapter.chats"), detail: tr("autocomplete.adapter.chatsDetail"), isOn: $store.prefs.adapterFromChats)
                .onChange(of: store.prefs.adapterFromChats) { _, _ in count() }
            trainRow
        } header: {
            SettingsSectionTitle(tr("autocomplete.adapter.title"), info: tr("autocomplete.adapter.info"))
        }
        .onAppear(perform: count)
    }

    @ViewBuilder private var progress: some View {
        switch training.phase {
        case .downloading(let fraction):
            StatusRow(title: tr("autocomplete.adapter.downloading"), detail: tr("autocomplete.adapter.downloadingDetail"), state: .todo) {
                HStack {
                    ProgressView(value: fraction).frame(width: 80)
                    stopButton
                }
            }
        case .preparing:
            StatusRow(title: tr("autocomplete.adapter.preparing"), detail: tr("autocomplete.adapter.runningDetail"), state: .todo) {
                HStack {
                    ProgressView().controlSize(.small)
                    stopButton
                }
            }
        case .training(let step, let of):
            StatusRow(title: tr("autocomplete.adapter.training", step, of), detail: tr("autocomplete.adapter.runningDetail"), state: .todo) {
                HStack {
                    ProgressView(value: Double(step), total: Double(max(of, 1))).frame(width: 80)
                    stopButton
                }
            }
        case .saving:
            StatusRow(title: tr("autocomplete.adapter.saving"), detail: "", state: .todo) { ProgressView().controlSize(.small) }
        case .noBetter:
            StatusRow(title: tr("autocomplete.adapter.noBetter"), detail: tr("autocomplete.adapter.noBetterDetail"), state: .warning) { EmptyView() }
        case .failed(let message):
            StatusRow(title: tr("autocomplete.adapter.failed"), detail: message, state: .error) { EmptyView() }
        case .idle, .done:
            EmptyView()
        }
    }

    @ViewBuilder private var trainRow: some View {
        if !training.phase.isRunning {
            if let obstacle = autocomplete.adapterObstacle(examples: examples) {
                SettingNote(note(for: obstacle))
            } else {
                LabeledContent {
                    Button(store.adapter == nil ? tr("autocomplete.adapter.train") : tr("autocomplete.adapter.retrain")) {
                        autocomplete.trainAdapter()
                    }
                    .buttonStyle(.borderedProminent)
                } label: {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(tr("autocomplete.adapter.examples", examples))
                        Text(tr("autocomplete.adapter.trainDetail"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
            }
        }
    }

    private var stopButton: some View {
        Button(tr("autocomplete.adapter.stop")) { training.stop() }
    }

    private func note(for obstacle: AutocompleteController.AdapterObstacle) -> String {
        switch obstacle {
        case .noGGUFModel: return tr("autocomplete.adapter.needsGGUF")
        case .unsupportedModel: return tr("autocomplete.adapter.unsupported")
        case .memory: return tr("autocomplete.adapter.memory")
        case .tooFewExamples(let count): return tr("autocomplete.adapter.tooFew", count, CompletionAdapter.minimumExamples)
        }
    }

    private func count() {
        examples = autocomplete.adapterExamples().count
    }
}
