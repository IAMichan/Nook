import SwiftUI
import AppKit

/// Settings › Privacy & security: permissions, log.
extension SettingsView {
    // MARK: Privacy and Access

    var privacySection: some View {
        Group {
            Section {
                permissionRow(tr("settings.privacy.screenReading"), detail: tr("settings.privacy.screenReadingDetail"), granted: CGPreflightScreenCaptureAccess()) {
                    _ = CGRequestScreenCaptureAccess()
                }
                permissionRow(tr("settings.privacy.calendar"), detail: tr("settings.privacy.calendarDetail"), granted: app.calendar.hasEventAccess) {
                    _ = await app.calendar.requestEvents(); app.connectors.refreshAll()
                }
                permissionRow(tr("settings.privacy.reminders"), detail: tr("settings.privacy.remindersDetail"), granted: app.calendar.hasReminderAccess) {
                    await app.calendar.requestReminders(); app.connectors.refreshAll()
                }
                permissionRow(tr("settings.privacy.micSpeech"), detail: tr("settings.privacy.micSpeechDetail"), granted: VoiceService.permissionsGranted) {
                    _ = await app.voice.requestPermissions()
                }
            } header: {
                Text(tr("settings.privacy.permissions"))
            } footer: {
                Text(tr("settings.privacy.permissionsFooter"))
            }
            .id(refreshTick)
            AuditLogSection()
            Section(tr("settings.privacy.whatLeavesMac")) {
                promise("eye.slash", tr("settings.privacy.noScreenshots"), tr("settings.privacy.noScreenshotsDetail"))
                promise("key", tr("settings.privacy.passwordsHidden"), tr("settings.privacy.passwordsHiddenDetail"))
                promise("hand.raised", tr("settings.privacy.nothingWithoutClick"), tr("settings.privacy.nothingWithoutClickDetail"))
                promise("lock", tr("settings.privacy.keysInKeychain"), tr("settings.privacy.keysInKeychainDetail"))
                Toggle(isOn: $settings.onlineLyrics) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("settings.privacy.onlineLyrics"))
                        Text(tr("settings.privacy.onlineLyricsDetail")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent(tr("settings.privacy.screenText")) {
                    Button(tr("settings.privacy.forgetScreenText")) {
                        app.screenContext.clear()
                        status = tr("settings.privacy.screenTextForgotten")
                    }
                }
            }
        }
    }

    func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(NookTheme.iris)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func permissionRow(_ title: String, detail: String, granted: Bool, request: @escaping @MainActor () async -> Void) -> some View {
        StatusRow(title: title, detail: detail, state: granted ? .done : .todo) {
            if granted {
                Text(tr("music.on")).foregroundStyle(.secondary)
            } else {
                Button(tr("button.allow")) {
                    app.requestPermission { await request(); refreshTick += 1 }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
