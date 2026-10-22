import Foundation
import Combine

/// The notices Nook gave since he started, so one you missed (a card that closed by itself, a strip while you were away,
/// a notice held back during a meeting) can still be read under the bell in the panel. The rules are in `NoticeLog`;
/// this publishes it. Kept in memory only, like the WhatsApp inbox: a notice can quote a message or a command, and
/// neither belongs on disk.
@MainActor
final class NoticeHistory: ObservableObject {
    static let shared = NoticeHistory()

    @Published private(set) var log = NoticeLog()

    var entries: [NoticeEntry] { log.entries }
    var unseen: Int { log.unseen }

    /// Keeps a notice. `key` ties notices about the same thing together (a newer one replaces the older); without one,
    /// every notice gets its own entry.
    func record(_ kind: NoticeEntry.Kind, title: String, detail: String = "", context: String = "",
                target: NoticeEntry.Target = .nowhere, key: String? = nil) {
        log.add(NoticeEntry(key: key ?? UUID().uuidString, kind: kind, title: title, detail: detail, context: context,
                            date: Date(), target: target))
    }

    func markAllSeen() {
        guard log.unseen > 0 else { return }
        log.markAllSeen()
    }

    func clear() {
        log.clear()
    }
}
