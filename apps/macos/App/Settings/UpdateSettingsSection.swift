import SwiftUI
import AppKit

/// Settings › Maintenance › Updates: which build this is, whether main (or, for a downloaded build, GitHub Releases) has
/// something newer, which release channel a downloaded build follows, checking now, and whether Nook checks by itself. Installing happens from the button in the panel
/// footer, which this opens.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Section {
            if let source = updater.source {
                StatusRow(title: status.title, detail: status.detail, state: status.state) { actions }
                LabeledContent(tr("update.settings.build")) {
                    Text(verbatim: [source.shortCommit, source.branch, source.configuration].compactMap { $0 }.joined(separator: " · "))
                        .font(NookTheme.TextStyle.code)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                }
                SettingToggle(tr("update.settings.auto"), detail: tr("update.settings.autoDetail"), isOn: $updater.autoCheck)
            } else if let release = updater.release {
                StatusRow(title: status.title, detail: status.detail, state: status.state) { actions }
                LabeledContent(tr("update.settings.version")) {
                    Text(verbatim: release.version.description)
                        .font(NookTheme.TextStyle.code)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                }
                Picker(selection: $updater.channel) {
                    Text(tr("update.channel.stable")).tag(UpdateChannel.stable)
                    Text(tr("update.channel.beta")).tag(UpdateChannel.beta)
                } label: {
                    SettingText("update.channel.title")
                }
                .pickerStyle(.segmented)
                .disabled(installing)
                .help(tr("update.channel.detail"))
                SettingNote(channelNote(for: release))
                if let manual = updater.manualRelease {
                    StatusRow(title: tr("update.release.manual.title", manual.version.description),
                              detail: tr(release.publicKey == nil ? "update.release.noKey" : "update.release.unsigned"), state: .warning) {
                        if let page = manual.page {
                            Button(tr("update.release.download")) { NSWorkspace.shared.open(page) }
                                .controlSize(.small)
                        }
                    }
                }
                SettingToggle(tr("update.settings.auto"), detail: tr("update.release.autoDetail"), isOn: $updater.autoCheck)
            } else {
                StatusRow(title: tr("update.settings.unavailableTitle"), detail: tr("update.settings.unavailable"), state: .todo) {
                    EmptyView()
                }
            }
        } header: {
            SettingsSectionTitle(tr("update.settings.title"),
                                 info: tr(updater.isReleaseBuild ? "update.release.footer" : "update.settings.footer"))
        }
    }

    /// An install under way keeps the channel it started on.
    private var installing: Bool {
        switch updater.phase {
        case .installing, .readyToRestart: return true
        default: return false
        }
    }

    /// What the chosen channel brings; a beta on Stable says it waits for the next regular release.
    private func channelNote(for release: ReleaseBuild) -> String {
        switch updater.channel {
        case .beta: return tr("update.channel.betaNote")
        case .stable where release.version.isPrerelease: return tr("update.channel.waitNote", release.version.description)
        case .stable: return tr("update.channel.stableNote")
        }
    }

    /// Check now, or open the panel when there is something to do there.
    private var actions: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if updater.phase == .checking {
                ProgressView().controlSize(.small)
            }
            switch updater.phase {
            case .available, .installing, .readyToRestart, .readyToBuildInXcode, .failed:
                Button(tr("update.settings.open")) { updater.showPanel() }
                    .buttonStyle(.nookProminent)
                    .controlSize(.small)
            default:
                Button(tr("update.settings.checkNow")) { updater.check() }
                    .controlSize(.small)
                    .disabled(updater.phase == .checking)
            }
        }
    }

    private var status: (title: String, detail: String, state: StatusState) {
        let checked = updater.lastChecked.map { tr("update.settings.lastChecked", NookDates.ago($0)) }
        switch updater.phase {
        case .available:
            if let release = updater.releaseUpdate {
                return (tr("update.release.status.available", release.version.description), checked ?? "", .warning)
            }
            return (tr("update.settings.status.available", updater.available?.count ?? 0), checked ?? "", .warning)
        case .installing(let step):
            return (tr("update.installing.title"), UpdateText.step(step), .todo)
        case .readyToRestart:
            return (tr("update.ready.title"), tr("update.menu.restart"), .warning)
        case .readyToBuildInXcode:
            return (tr("update.xcode.title"), tr("update.menu.xcode"), .warning)
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
