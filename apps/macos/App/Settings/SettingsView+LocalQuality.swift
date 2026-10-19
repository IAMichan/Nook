import SwiftUI

/// Settings › Brain: making a small local brain answer better, and measuring it.
struct LocalQualitySection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var settings: AppSettings
    @StateObject private var runner = LocalEvalRunner()
    @State private var showDetails = false

    var body: some View {
        Section {
            SettingToggle(tr("settings.quality.evidence"), detail: tr("settings.quality.evidenceDetail"), isOn: $settings.evidenceFirst)
            SettingToggle(tr("settings.quality.check"), detail: tr("settings.quality.checkDetail"), isOn: $settings.checkAnswers)
            HStack {
                if runner.running {
                    ProgressView(value: Double(runner.done), total: Double(runner.total))
                        .frame(maxWidth: 160)
                    Text("\(runner.done)/\(runner.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(tr("button.cancel")) { runner.cancel() }
                } else {
                    Button(tr("settings.quality.measure")) { runner.start(brain: app.brain, settings: settings) }
                        .disabled(!settings.brainReady)
                }
                Spacer()
                if !runner.results.isEmpty, !runner.running {
                    Text(tr("settings.quality.score", runner.passed, runner.results.count, Int(runner.totalSeconds)))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(runner.passed * 4 >= runner.results.count * 3 ? Color.green : Color.orange)
                }
            }
            if let failure = runner.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
            if !runner.results.isEmpty {
                DisclosureGroup(tr("settings.quality.details"), isExpanded: $showDetails) {
                    ForEach(runner.results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(result.question, systemImage: result.verdict.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.verdict.passed ? Color.green : Color.red)
                            Text(result.answer).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                            if !result.verdict.passed {
                                Text(tr("settings.quality.missing", (result.verdict.missing + result.verdict.forbidden.map { "✗ " + $0 }).joined(separator: ", ")))
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if !runner.history.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("settings.quality.history")).font(.caption).foregroundStyle(.secondary)
                    ForEach(runner.history, id: \.self) { Text($0).font(.caption2.monospacedDigit()) }
                }
            }
        } header: {
            Text(tr("settings.quality.title"))
        } footer: {
            Text(tr("settings.quality.footer"))
        }
    }
}
