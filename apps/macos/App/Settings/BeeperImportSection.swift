import SwiftUI
import AppKit

/// Settings › Connections, for someone coming from Beeper: one row that opens the move in a sheet (`BeeperImportSheet`):
/// bringing over what Beeper Desktop has in one click (`BeeperImporter`), then every app that was linked there.
struct BeeperImportSection: View {
    let setCollecting: (Bool) -> Void
    @ObservedObject private var importer = BeeperImporter.shared
    @State private var showing = false

    var body: some View {
        Section {
            SettingsLinkRow(title: tr("beeper.import.title"),
                            detail: importer.imported == nil ? tr("beeper.import.rowDetail") : tr("beeper.import.rowDone")) {
                showing = true
            }
        } header: {
            SettingsSectionTitle(tr("beeper.import.header"), info: tr("beeper.import.footer"))
        }
        .sheet(isPresented: $showing) {
            BeeperImportSheet(setCollecting: setCollecting)
        }
    }
}

/// The move from Beeper in numbered steps, as every setup in Settings: Beeper's token, bringing everything over, linking
/// each app that was linked there (one connection row each), and Nook saying what came over. Saying the move is done
/// sits on the left of the buttons, as removing does.
struct BeeperImportSheet: View {
    let setCollecting: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var importer = BeeperImporter.shared
    // Linking an app in its sheet changes these: the rows follow.
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @State private var token = ""
    @State private var open: ChatAppSheetItem?
    @State private var confirmFinish = false

    var body: some View {
        SetupSheet(title: tr("beeper.import.title"), subtitle: tr("beeper.import.intro")) {
            ServiceTile(domain: "beeper.com", fallback: "arrow.down.circle.fill", tint: NookTheme.iris, size: 48)
        } content: {
            SetupStep(number: 1, title: tr("beeper.import.token"), done: importer.hasToken) {
                if !importer.hasToken { tokenStep }
            }
            SetupStep(number: 2, title: tr("beeper.import.run"), done: importer.imported != nil) {
                if importer.hasToken { runStep }
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
            SetupCheckStep(number: importer.apps.isEmpty ? 3 : 4, title: tr("import.check.title"),
                           detail: tr("beeper.import.checkDetail"), state: checkState)
        } footer: {
            Button(tr("beeper.import.finish")) { confirmFinish = true }
                .disabled(importer.isBusy)
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .sheetPrimaryButton()
        }
        .confirmationDialog(tr("beeper.import.finish"), isPresented: $confirmFinish, titleVisibility: .visible) {
            Button(tr("beeper.import.finishButton")) {
                importer.finish()
                dismiss()
            }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: {
            Text(tr("beeper.import.finishDetail"))
        }
        .sheet(item: $open) { item in
            ChatAppSheet(app: item.id, setCollecting: setCollecting)
        }
    }

    /// What came over: nothing yet, the import running, or how many of Beeper's apps are linked here now.
    private var checkState: SetupCheckState {
        guard let imported = importer.imported else { return importer.isBusy ? .checking : .idle }
        let apps = importer.apps
        guard !apps.isEmpty else { return .passed(summary(imported)) }
        let linked = apps.count(where: { ChatAppStates.state($0)?.linked == true })
        return .passed(tr("beeper.import.checkApps", linked, apps.count))
    }

    /// Beeper's access token, pasted once: Nook did not keep one yet.
    @ViewBuilder
    private var tokenStep: some View {
        StepAction(detail: tr("beeper.import.tokenDetail"), button: tr("beeper.import.openBeeper"), prominent: false) { openBeeper() }
        SecureField("", text: $token, prompt: Text(tr("beeper.import.token")).foregroundStyle(NookTheme.textTertiary))
            .labelsHidden()
            .settingsField()
            .frame(maxWidth: .infinity)
            .onSubmit { saveToken() }
        Button(tr("chats.slack.save")) { saveToken() }
            .buttonStyle(.nookProminent)
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The move itself, on your own click; again after linking more apps in Beeper, or to pick up what changed.
    @ViewBuilder
    private var runStep: some View {
        StepAction(detail: tr("beeper.import.runDetail"),
                   button: importer.imported == nil ? tr("beeper.import.start") : tr("beeper.import.again"),
                   prominent: importer.imported == nil, disabled: importer.isBusy) {
            Task { await importer.run(setCollecting: setCollecting) }
        }
        if importer.isBusy { ProgressView().controlSize(.small) }
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
