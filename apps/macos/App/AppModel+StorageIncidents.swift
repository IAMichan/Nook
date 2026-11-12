import AppKit
import Combine

/// The databases of Nook's own that could not be used as they were this launch (`DatabaseIncidents`), as the panel's
/// corner shows them until you dismiss them: in the main window and in the notch's panel alike (`PanelApprovalBar`), so
/// they reach you with the notch off too.
@MainActor
final class StorageNotices: ObservableObject {
    static let shared = StorageNotices()

    @Published private(set) var shown: [DatabaseIncident] = []

    func show(_ incident: DatabaseIncident) {
        shown.removeAll { $0.id == incident.id }
        shown.append(incident)
    }

    func dismiss(_ id: String) {
        shown.removeAll { $0.id == id }
    }
}

/// Saying it when a database could not be opened (`SQLiteRecovery`): which file, why, where the copy is, how to recover.
extension AppModel {
    /// Shows the incidents of the stores that opened before the panel did (nook.sqlite opens with `AppModel`), and every
    /// later one (the chat archive and the timelines open on first use).
    func watchStorageIncidents() {
        for incident in DatabaseIncidents.shared.all { tellStorageIncident(incident) }
        DatabaseIncidents.shared.onRecord { [weak self] incident in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tellStorageIncident(incident) } }
        }
    }

    /// Kept in the notice history, waits in the panel's corner, and comes up as a card on the notch when it shows.
    func tellStorageIncident(_ incident: DatabaseIncident) {
        guard !demoMode else { return }
        StorageNotices.shared.show(incident)
        let words = Self.storageWords(incident)
        logNotice(.failed, title: words.title, detail: [words.detail, words.recover].compactMap { $0 }.joined(separator: " "))
        let token = "storage-" + incident.file.lastPathComponent
        viewModel.register("\(token)#reveal") { [weak self] in self?.revealStorageCopy(incident) }
        viewModel.register("\(token)#copy") { [weak self] in self?.copyRecoveryCommand(incident) }
        var facts = [Fact(label: tr("storage.fact.file"), value: incident.file.path),
                     Fact(label: tr("storage.fact.reason"), value: incident.reason)]
        if let copy = incident.movedTo { facts.append(Fact(label: tr("storage.fact.copy"), value: copy.path)) }
        if let recover = words.recover { facts.append(Fact(label: tr("storage.fact.recover"), value: recover)) }
        let card = NookCard(
            id: token,
            mood: .worry,
            context: tr("storage.context"),
            title: words.title,
            detail: .facts(facts),
            primary: incident.movedTo == nil
                ? CardAction(label: tr("app.ok"), outcome: .dismiss)
                : CardAction(label: tr("storage.action.reveal"), outcome: .callback("\(token)#reveal", "")),
            secondary: incident.recoverCommand == nil
                ? CardAction(label: "", outcome: .dismiss)
                : CardAction(label: tr("storage.action.copy"), outcome: .callback("\(token)#copy", "")),
            contentHeight: 150 + CGFloat(facts.count) * 44,
            status: CardStatus(text: tr("card.status.error"), tone: .failed)
        )
        viewModel.present(card)
    }

    /// What the notice says: title, the line under it, and for a file moved aside how to get its data back.
    static func storageWords(_ incident: DatabaseIncident) -> (title: String, detail: String, recover: String?) {
        let name = incident.file.lastPathComponent
        let holds: String
        switch name {
        case "nook.sqlite": holds = tr("storage.holds.nook")
        case "chats.sqlite": holds = tr("storage.holds.chats")
        case "runs.sqlite": holds = tr("storage.holds.runs")
        default: holds = tr("storage.holds.other")
        }
        switch incident.kind {
        case .damaged:
            let copy = incident.movedTo?.lastPathComponent ?? "—"
            return (tr("storage.damaged.title", name), tr("storage.damaged.detail", incident.reason, copy, holds),
                    tr("storage.damaged.recover", incident.file.path))
        case .unavailable:
            return (tr("storage.unavailable.title", name),
                    tr("storage.unavailable.detail", incident.reason, holds, incident.file.deletingLastPathComponent().path),
                    nil)
        }
    }

    /// The copy in Finder (or the file itself, when nothing was moved).
    func revealStorageCopy(_ incident: DatabaseIncident) {
        NSWorkspace.shared.activateFileViewerSelecting([incident.movedTo ?? incident.file])
    }

    /// The command that reads what is still readable from the copy into a new file beside it.
    func copyRecoveryCommand(_ incident: DatabaseIncident) {
        guard let command = incident.recoverCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        ToastCenter.shared.success(tr("storage.copied"))
    }
}
