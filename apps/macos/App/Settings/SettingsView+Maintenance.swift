import SwiftUI
import AppKit

/// Settings › Maintenance: keeping Nook up to date, how much it does on its own, and what helps track down a problem.
/// Settings › About Nook: which Nook this is, where its source lives, and its license. Both close the sidebar, as
/// Maintenance and About do.
extension SettingsView {
    // MARK: Maintenance

    var maintenanceSection: some View {
        Group {
            UpdateSettingsSection()
            energySection
            Section {
                SettingToggle(tr("settings.ws.trafficLog"), detail: tr("settings.ws.trafficLog.footer"),
                              isOn: $workspace.providerTrafficLog)
                Toggle(isOn: $app.demoMode) { SettingText("settings.notch.demoData") }
            } header: {
                SettingText("settings.maintenance.diagnostics")
            }
        }
    }

    // MARK: About

    var aboutSection: some View {
        Group {
            Section(tr("settings.about.app")) {
                LabeledContent {
                    Text(verbatim: Self.versionText)
                        .font(NookTheme.TextStyle.code)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                } label: {
                    SettingText("settings.about.version")
                }
                aboutLink(tr("settings.about.source"), Self.repository)
                aboutLink(tr("settings.about.changes"), Self.repository.appendingPathComponent("blob/main/CHANGELOG.md"))
                aboutLink(tr("settings.about.report"), Self.repository.appendingPathComponent("issues/new"))
            }
            Section(tr("settings.about.legal")) {
                LabeledContent {
                    Button(tr("settings.about.licenseValue")) {
                        NSWorkspace.shared.open(Self.repository.appendingPathComponent("blob/main/LICENSE"))
                    }
                    .buttonStyle(.link)
                } label: {
                    SettingText("settings.about.license")
                }
                aboutLink(tr("settings.about.notices"), Self.repository.appendingPathComponent("blob/main/THIRD-PARTY-NOTICES.md"))
            }
        }
    }

    private static let repository = URL(string: "https://github.com/IAMichan/nook")!

    /// "0.1.0 (42)", with the commit and branch for a build from source.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        var text = build.map { "\(version) (\($0))" } ?? version
        if let source = AppUpdater.shared.source {
            text += " · " + [source.shortCommit, source.branch].compactMap { $0 }.joined(separator: " · ")
        }
        return text
    }

    private func aboutLink(_ title: String, _ url: URL) -> some View {
        LabeledContent(title) {
            Button(tr("settings.about.open")) { NSWorkspace.shared.open(url) }
                .controlSize(.small)
                .help(url.absoluteString)
        }
    }
}
