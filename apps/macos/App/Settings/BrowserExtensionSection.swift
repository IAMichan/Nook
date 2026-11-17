import SwiftUI

/// Settings › Editor & browser › Nook in your browser: connects Nook to the user's own Chromium browsers through Nook's
/// extension (`BrowserExtensionService`). Connect writes the host the extension talks to, and opens the extension's
/// Chrome Web Store page when no browser has it yet. The status recognizes the extension by itself: connected, found in
/// a browser (connecting), switched off there, or not added yet.
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
            if service.enabled { status }
            if let error = service.error { SettingNote(error, tone: .error) }
        }
        .task(id: service.enabled) {
            // While this page is open: who is connected, read from Nook's own bookkeeping (no browser is asked), and
            // which browsers have the extension, read from their preferences, so loading it shows without a click.
            while service.enabled, !Task.isCancelled {
                service.refresh()
                if service.connected.isEmpty { await service.scanInstalls() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        let browsers = service.connected.map { $0.browser.isEmpty ? tr("browserExt.source.unnamed") : $0.browser }
        let switchedOn = service.browsersWithExtension(enabled: true)
        let switchedOff = service.browsersWithExtension(enabled: false)
        if !browsers.isEmpty {
            SettingNote(tr("browserExt.settings.connected", browsers.joined(separator: ", ")), tone: .success)
        } else if service.installedBrowsers.isEmpty {
            SettingNote(tr("browserExt.settings.noBrowser"), tone: .warning)
        } else if !switchedOn.isEmpty {
            // In the browser already: it connects by itself as soon as its worker wakes (switching to the browser does).
            SettingNote(tr("browserExt.settings.found", switchedOn.joined(separator: ", ")))
        } else if let browser = switchedOff.first {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                SettingNote(tr("browserExt.settings.switchedOff", switchedOff.joined(separator: ", ")), tone: .warning)
                Spacer(minLength: NookTheme.Spacing.md)
                Button(tr("browserExt.settings.openPage")) { service.openExtensionsPage(in: browser) }
            }
        } else {
            // Not in any browser yet: Connect opened the store page; the button opens it again.
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                SettingNote(tr("browserExt.settings.waiting"), tone: .warning)
                Spacer(minLength: NookTheme.Spacing.md)
                Button(tr("browserExt.settings.install")) { service.openStorePage() }
            }
        }
    }
}
