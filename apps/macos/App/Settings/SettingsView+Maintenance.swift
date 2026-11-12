import SwiftUI
import AppKit

/// Settings › Maintenance: keeping Nook up to date, how much it does on its own, and what helps track down a problem.
/// Settings › About Nook: which Nook this is, where its source lives, and its license. Both close the sidebar.
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
                LabeledContent {
                    Button(tr("diagnostics.copy")) { copyRedactedDiagnostics() }
                        .controlSize(.small)
                } label: {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        Text(tr("diagnostics.export"))
                        Text(tr("diagnostics.export.detail"))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
            } header: {
                SettingText("settings.maintenance.diagnostics")
            }
            TelemetrySettingsSection()
        }
    }

    /// Puts a redacted report on the clipboard: versions and set-up facts, with mail addresses, tokens, phone numbers and
    /// the user's name in paths taken out (`DiagnosticsRedactor`). Nothing is sent anywhere.
    private func copyRedactedDiagnostics() {
        let info = Bundle.main.infoDictionary
        let header: [(String, String)] = [
            ("Version", info?["CFBundleShortVersionString"] as? String ?? "-"),
            ("Build", info?["CFBundleVersion"] as? String ?? "-"),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Language", I18n.shared.currentLanguage.rawValue),
            ("Demo mode", app.demoMode ? "on" : "off"),
        ]
        Pasteboard.copy(DiagnosticsRedactor.report(header: header, log: []))
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
                    .buttonStyle(.nookLink)
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
