import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Privacy & security: privacy level, permissions, apps Nook never reads, log.
extension SettingsView {
    // MARK: Privacy and Access

    var privacySection: some View {
        Group {
            privacyLevelSection
            Section {
                ForEach(SystemPermission.allCases) { permission in
                    permissionRow(permission.title, detail: permission.detail, granted: permissions.isGranted(permission)) {
                        await permissions.request(permission, app: app)
                    }
                }
            } header: {
                Text(tr("settings.privacy.permissions"))
            } footer: {
                Text(tr("settings.privacy.permissionsFooter"))
            }
            .onAppear { permissions.watch() }
            .onDisappear { permissions.unwatch() }
            privateSourcesSection
            neverReadAppsSection
            AuditLogSection()
            Section(tr("settings.privacy.whatLeavesMac")) {
                promise("eye.slash", tr("settings.privacy.noScreenshots"), tr("settings.privacy.noScreenshotsDetail"))
                promise("key", tr("settings.privacy.passwordsHidden"), tr("settings.privacy.passwordsHiddenDetail"))
                promise("hand.raised", tr("settings.privacy.nothingWithoutClick"), tr("settings.privacy.nothingWithoutClickDetail"))
                promise("lock", tr("settings.privacy.keysInKeychain"), tr("settings.privacy.keysInKeychainDetail"))
                SettingToggle(tr("settings.privacy.onlineLyrics"), detail: tr("settings.privacy.onlineLyricsDetail"),
                              isOn: $settings.onlineLyrics)
                LabeledContent(tr("settings.privacy.screenText")) {
                    Button(tr("settings.privacy.forgetScreenText")) {
                        app.screenContext.clear()
                        status = tr("settings.privacy.screenTextForgotten")
                    }
                }
            }
        }
    }

    /// How tightly Nook guards what an external brain sees: one choice, what it means, and whether it applies right now.
    private var privacyLevelSection: some View {
        Section {
            Picker(selection: $settings.privacyLevel) {
                ForEach(PrivacyLevel.allCases) { level in
                    Text(tr(level.titleKey)).tag(level)
                }
            } label: {
                SettingLabel(tr("settings.privacy.level"), detail: tr("settings.privacy.levelDetail"))
            }
            .pickerStyle(.segmented)
            Text(tr(settings.privacyLevel.detailKey))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.isLocalBrain {
                Text(tr("settings.privacy.level.localBrain"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(tr("settings.privacy.levelTitle"))
        } footer: {
            Text(tr("settings.privacy.levelFooter"))
        }
    }

    /// Apps Nook never reads: not the screen text, not through accessibility or scripting, and no suggestions while typing.
    private var neverReadAppsSection: some View {
        Section {
            ForEach(settings.neverReadApps, id: \.self) { bundleID in
                HStack {
                    Label(Self.appName(bundleID), systemImage: "eye.slash")
                    Spacer()
                    Button(tr("settings.privacy.neverRead.remove")) {
                        settings.neverReadApps.removeAll { $0 == bundleID }
                    }
                    .controlSize(.small)
                }
            }
            Button(tr("settings.privacy.neverRead.add")) { chooseNeverReadApp() }
        } header: {
            Text(tr("settings.privacy.neverRead.title"))
        } footer: {
            Text(tr("settings.privacy.neverRead.footer"))
        }
    }

    private func chooseNeverReadApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            .filter { !ScreenReader.builtInExcluded.contains($0) && !settings.neverReadApps.contains($0) }
        guard !picked.isEmpty else { return }
        settings.neverReadApps += picked
        // Text Nook already read from these apps is dropped at once, not at the next read.
        app.screenContext.clear()
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(NookTheme.font(14))
                .foregroundStyle(NookTheme.iris)
                .frame(width: 22)
            SettingLabel(title, detail: detail)
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
