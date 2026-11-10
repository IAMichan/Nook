import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Privacy, in four pages: the privacy level (what never leaves the Mac, forgetting what Nook just
/// saw), access (the Mac's permissions and the apps Nook never reads), the sources only a brain on this Mac may read,
/// and the log. Whether Nook may look up lyrics online is with the music under Connections.
extension SettingsView {
    // MARK: Privacy and Access

    /// The four Privacy pages: how tightly Nook guards what leaves the Mac, what it may access, what stays on this Mac,
    /// and the log of what it did.
    enum PrivacyPart { case level, access, onDevice, log }

    @ViewBuilder
    func privacySection(_ part: PrivacyPart) -> some View {
        switch part {
        case .level:
            privacyLevelSection
            Section {
                LabeledContent(tr("settings.privacy.screenText")) {
                    ConfirmedButton(tr("settings.privacy.forgetScreenText"), question: tr("confirm.forgetScreenText")) {
                        app.screenContext.clear()
                        ToastCenter.shared.success(tr("settings.privacy.screenTextForgotten"))
                    }
                }
            }
        case .access:
            Section {
                ForEach(SystemPermission.allCases) { permission in
                    permissionRow(permission.title, detail: permission.detail, granted: permissions.isGranted(permission)) {
                        await permissions.request(permission, app: app)
                    }
                }
            } header: {
                SettingText("settings.privacy.permissions")
            }
            .onAppear { permissions.watch() }
            .onDisappear { permissions.unwatch() }
            neverReadAppsSection
        case .onDevice:
            privateSourcesSection
        case .log:
            AuditLogSection()
        }
    }

    /// How tightly Nook guards what an external brain sees: one choice, what it means, and whether it applies right now.
    @ViewBuilder
    private var privacyLevelSection: some View {
        Section {
            Picker(selection: $settings.privacyLevel) {
                ForEach(PrivacyLevel.allCases) { level in
                    Text(tr(level.titleKey)).tag(level)
                }
            } label: {
                Text(tr("settings.privacy.level"))
            }
            .pickerStyle(.segmented)
            .help(tr("settings.privacy.levelDetail"))
            SettingNote(tr(settings.privacyLevel.detailKey))
            if settings.isLocalBrain {
                SettingNote(tr("settings.privacy.level.localBrain"), tone: .success)
            }
        } header: {
            SettingText("settings.privacy.levelTitle")
        }
        // What Nook promises whatever the level: four facts, a folded group of their own under the choice.
        SettingsFold(tr("settings.privacy.whatLeavesMac"), summary: tr("settings.privacy.promisesSummary"),
                     keys: ["settings.privacy.whatLeavesMac"]) {
            promise("eye.slash", tr("settings.privacy.noScreenshots"), tr("settings.privacy.noScreenshotsDetail"))
            promise("key", tr("settings.privacy.passwordsHidden"), tr("settings.privacy.passwordsHiddenDetail"))
            promise("hand.raised", tr("settings.privacy.nothingWithoutClick"), tr("settings.privacy.nothingWithoutClickDetail"))
            promise("lock", tr("settings.privacy.keysInKeychain"), tr("settings.privacy.keysInKeychainDetail"))
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
            SettingsSectionTitle(tr("settings.privacy.neverRead.title"), info: tr("settings.privacy.neverRead.footer"))
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

    /// One promise on one line; the longer explanation shows on hover.
    func promise(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            Image(icon: symbol)
                .font(NookTheme.font(14))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 22)
            Text(title)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }

    func permissionRow(_ title: String, detail: String, granted: Bool, request: @escaping @MainActor () async -> Void) -> some View {
        // Once granted, the row is just its name and a check; why Nook asks only shows while it still has to.
        StatusRow(title: title, detail: granted ? "" : detail, state: granted ? .done : .todo) {
            // Granted needs no word: the check in front of the row says it.
            if !granted {
                Button(tr("button.allow")) {
                    app.requestPermission { await request(); refreshTick += 1 }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }
}
