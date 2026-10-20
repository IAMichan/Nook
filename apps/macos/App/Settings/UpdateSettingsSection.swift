import SwiftUI
import AppKit

/// Settings › Overview › Updates: which build this is, whether main has something newer, checking now, and whether Nook
/// checks by itself. Installing happens from the button in the Agents footer, which this opens.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Section {
            if let source = updater.source {
                StatusRow(title: status.title, detail: status.detail, state: status.state) {
                    HStack(spacing: 8) {
                        if updater.phase == .checking {
                            ProgressView().controlSize(.small)
                        }
                        switch updater.phase {
                        case .available, .installing, .readyToRestart, .failed:
                            Button(tr("update.settings.open")) { updater.showPanel() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        default:
                            Button(tr("update.settings.checkNow")) { updater.check() }
                                .controlSize(.small)
                                .disabled(updater.phase == .checking)
                        }
                    }
                }
                LabeledContent(tr("update.settings.build")) {
                    Text(verbatim: [source.shortCommit, source.branch, source.configuration].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingToggle(tr("update.settings.auto"), detail: tr("update.settings.autoDetail"), isOn: $updater.autoCheck)
            } else {
                StatusRow(title: tr("update.settings.unavailableTitle"), detail: tr("update.settings.unavailable"), state: .todo) {
                    EmptyView()
                }
            }
        } header: {
            Text(tr("update.settings.title"))
        } footer: {
            Text(tr("update.settings.footer"))
        }
    }

    private var status: (title: String, detail: String, state: StatusState) {
        let checked = updater.lastChecked.map { tr("update.settings.lastChecked", NookDates.ago($0)) }
        switch updater.phase {
        case .available:
            return (tr("update.settings.status.available", updater.available?.count ?? 0), checked ?? "", .warning)
        case .installing(let step):
            return (tr("update.installing.title"), UpdateText.step(step), .todo)
        case .readyToRestart:
            return (tr("update.ready.title"), tr("update.menu.restart"), .warning)
        case .failed(let failure):
            return (tr("update.failed.title"), UpdateText.reason(failure.reason, branch: updater.available?.branch ?? "main"), .error)
        case .checking:
            return (tr("update.settings.status.checking"), checked ?? "", .todo)
        case .upToDate:
            return (tr("update.settings.status.upToDate"), checked ?? "", .done)
        case .idle, .unavailable:
            if let problem = updater.checkProblem { return (tr("update.settings.status.problem"), problem, .warning) }
            return (tr("update.settings.status.never"), "", .todo)
        }
    }
}
