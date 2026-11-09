import SwiftUI
import AppKit

/// Settings › Connections, for someone coming from Beeper: bringing over what Beeper Desktop has in one click (`BeeperImporter`),
/// then every app that was linked there with its Link button, until you say the move is done.
struct BeeperImportSection: View {
    let setCollecting: (Bool) -> Void
    @ObservedObject private var importer = BeeperImporter.shared
    // Linking an app in its sheet changes these: the rows follow.
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @State private var token = ""
    @State private var open: ChatAppSheetItem?

    /// The move in numbered steps, as every setup in Settings: Beeper's token, bringing everything over, linking each app
    /// that was linked there (one connection row each), and saying the move is done.
    var body: some View {
        Section {
            IntroCard(title: tr("beeper.import.title"), text: tr("beeper.import.intro"))
            SetupStep(number: 1, title: tr("beeper.import.token"), done: importer.hasToken) {
                if !importer.hasToken { tokenRow }
            }
            SetupStep(number: 2, title: tr("beeper.import.run"), done: importer.imported != nil) {
                if importer.hasToken { runRow }
                if let problem = importer.problem {
                    SettingNote(problem, tone: .warning)
                }
                if let imported = importer.imported {
                    SettingNote(tr("beeper.import.done") + " " + summary(imported), tone: .success)
                }
            }
            if !importer.apps.isEmpty {
                SetupStep(number: 3, title: tr("beeper.import.apps"),
                          done: importer.apps.allSatisfy { ChatAppStates.state($0)?.linked == true }) {
                    ForEach(importer.apps, id: \.self) { row($0) }
                }
            }
            SetupStep(number: importer.apps.isEmpty ? 3 : 4, title: tr("beeper.import.finish")) {
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("beeper.import.finishDetail"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("beeper.import.finishButton")) { importer.finish() }
                        .disabled(importer.isBusy)
                }
            }
        } header: {
            SettingsSectionTitle(tr("beeper.import.header"), info: tr("beeper.import.footer"))
        }
        .sheet(item: $open) { item in
            ChatAppSheet(app: item.id, setCollecting: setCollecting)
        }
    }

    /// Beeper's access token, pasted once: Nook did not keep one yet.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("beeper.import.tokenDetail"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NookTheme.Spacing.sm) {
                SecureField("", text: $token, prompt: Text(tr("beeper.import.token")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { saveToken() }
                Button(tr("chats.slack.save")) { saveToken() }
                    .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(tr("beeper.import.openBeeper")) { openBeeper() }
            }
        }
    }

    /// The move itself, on your own click; again after linking more apps in Beeper, or to pick up what changed.
    private var runRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Text(tr("beeper.import.runDetail"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if importer.isBusy { ProgressView().controlSize(.small) }
            Button(importer.imported == nil ? tr("beeper.import.start") : tr("beeper.import.again")) {
                Task { await importer.run(setCollecting: setCollecting) }
            }
            .disabled(importer.isBusy)
        }
    }

    /// One app that was linked in Beeper, in the one connection row: linked in Nook already, or Link in its "…" menu and
    /// on a click (its steps open in a sheet, as adding anything does).
    private func row(_ app: String) -> some View {
        let known = MessagingApps.app(id: app)
        let linked = ChatAppStates.state(app)?.linked == true
        return ConnectionRow(title: known?.name ?? app, status: linked ? .connected : .notLinked,
                             detail: detail(app, linked: linked)) {
            ServiceTile(domain: known?.site, fallback: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, size: 28,
                        source: app)
        } menu: {
            if !linked {
                Button(tr("chats.apps.link")) { open = ChatAppSheetItem(id: app) }
            }
        }
    }

    private func detail(_ app: String, linked: Bool) -> String {
        if linked { return tr("beeper.import.linkedHere") }
        guard ChatAppsCatalog.ownWay.contains(app) || ChatHelper.apps.contains(app) else { return tr("beeper.import.notifications") }
        let names = importer.accounts.filter { $0.app == app }.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? tr("beeper.import.linkAgain") : tr("beeper.import.wasLinkedAs", names.joined(separator: ", "))
    }

    private func summary(_ imported: (chats: Int, settings: Int)) -> String {
        imported.settings > 0 ? tr("beeper.import.summarySettings", imported.chats, imported.settings)
            : tr("beeper.import.summary", imported.chats)
    }

    private func saveToken() {
        guard importer.saveToken(token) else {
            ToastCenter.shared.error(tr("chats.slack.notSaved"))
            return
        }
        token = ""
    }

    private func openBeeper() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BeeperImport.bundleID) else {
            if let site = URL(string: "https://developers.beeper.com/desktop-api/") { NSWorkspace.shared.open(site) }
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
