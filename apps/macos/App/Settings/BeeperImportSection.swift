import SwiftUI
import AppKit

/// Settings › Chats, for someone coming from Beeper: bringing over what Beeper Desktop has in one click (`BeeperImporter`),
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

    var body: some View {
        Section {
            IntroCard(title: tr("beeper.import.title"), text: tr("beeper.import.intro"))
            if importer.hasToken {
                runRow
            } else {
                tokenRow
            }
            if let problem = importer.problem {
                SettingNote(problem, tone: .warning)
            }
            if let imported = importer.imported {
                StatusRow(title: tr("beeper.import.done"), detail: summary(imported), state: .done) { EmptyView() }
            }
            if !importer.apps.isEmpty {
                NookSectionLabel(tr("beeper.import.apps"))
                ForEach(importer.apps, id: \.self) { row($0) }
            }
            HStack(spacing: NookTheme.Spacing.md) {
                SettingLabel(tr("beeper.import.finish"), detail: tr("beeper.import.finishDetail"))
                Spacer()
                Button(tr("beeper.import.finishButton")) { importer.finish() }
                    .disabled(importer.isBusy)
            }
        } header: {
            Text(tr("beeper.import.header"))
        } footer: {
            Text(tr("beeper.import.footer"))
        }
        .sheet(item: $open) { item in
            ChatAppSheet(app: item.id, setCollecting: setCollecting)
        }
    }

    /// Beeper's access token, pasted once: Nook did not keep one yet.
    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            SettingLabel(tr("beeper.import.token"), detail: tr("beeper.import.tokenDetail"))
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
            SettingLabel(tr("beeper.import.run"), detail: tr("beeper.import.runDetail"))
            Spacer()
            if importer.isBusy { ProgressView().controlSize(.small) }
            Button(importer.imported == nil ? tr("beeper.import.start") : tr("beeper.import.again")) {
                Task { await importer.run(setCollecting: setCollecting) }
            }
            .disabled(importer.isBusy)
        }
    }

    /// One app that was linked in Beeper: linked in Nook already, or its Link button.
    private func row(_ app: String) -> some View {
        let known = MessagingApps.app(id: app)
        let linked = ChatAppStates.state(app)?.linked == true
        return ServiceRowLayout(domain: known?.site, symbol: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris,
                                title: known?.name ?? app, detail: detail(app, linked: linked),
                                status: linked ? .connected : .notLinked, source: app) {
            if !linked {
                Button(tr("chats.apps.link")) { open = ChatAppSheetItem(id: app) }
                    .controlSize(.small)
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
