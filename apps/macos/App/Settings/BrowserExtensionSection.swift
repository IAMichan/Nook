import SwiftUI

/// Settings › Editor & browser › Nook in your browser: connects Nook to the user's own Chromium browsers through Nook's
/// extension (`BrowserExtensionService`). Connect writes the host the extension talks to and a copy of the extension;
/// the three steps say how to load it, and the status says which browser is connected now.
struct BrowserExtensionSection: View {
    @ObservedObject private var service = BrowserExtensionService.shared

    var body: some View {
        Section(tr("browserExt.settings.title")) {
            LabeledContent {
                if service.enabled {
                    Button(tr("browserExt.settings.disconnect")) { service.disconnect() }
                } else {
                    Button(tr("browserExt.settings.connect")) { service.connect() }
                }
            } label: {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    SettingText("browserExt.settings.label")
                    SettingNote(tr("browserExt.settings.detail"))
                }
            }
            if service.enabled {
                status
                steps
            }
            if let error = service.error { SettingNote(error, tone: .error) }
        }
        .task(id: service.enabled) {
            // While this page is open: who is connected, read from Nook's own bookkeeping (no browser is asked).
            while service.enabled, !Task.isCancelled {
                service.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let browsers = service.connected.map { $0.browser.isEmpty ? tr("browserExt.source.unnamed") : $0.browser }
        if browsers.isEmpty {
            SettingNote(tr("browserExt.settings.waiting"), tone: .warning)
        } else {
            SettingNote(tr("browserExt.settings.connected", browsers.joined(separator: ", ")), tone: .success)
        }
        if service.installedBrowsers.isEmpty {
            SettingNote(tr("browserExt.settings.noBrowser"), tone: .warning)
        } else {
            SettingNote(tr("browserExt.settings.hostFor", service.installedBrowsers.joined(separator: ", ")))
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            stepRow(1, tr("browserExt.settings.step1")) {
                Button(tr("browserExt.settings.copyAddress")) { service.copyExtensionsAddress() }
            }
            stepRow(2, tr("browserExt.settings.step2")) {
                Button(tr("browserExt.settings.showFolder")) { service.revealExtension() }
            }
            stepRow(3, tr("browserExt.settings.step3")) { EmptyView() }
        }
        .padding(.vertical, NookTheme.Spacing.xxs)
    }

    private func stepRow<Action: View>(_ number: Int, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
            Text("\(number).")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textMuted)
                .monospacedDigit()
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: NookTheme.Spacing.md)
            action()
        }
    }
}
