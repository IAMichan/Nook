import AppKit

/// Picks up a key or token you copied on a service's own page, so you never have to paste it: a sheet calls `watch()`
/// when its "Get a key" button opens that page, and when you come back to Nook a newly copied text that looks like a key
/// lands in `caught`. Nothing is read before that click, and the clipboard is read once per return to Nook.
@MainActor
final class ClipboardKeyCatcher: ObservableObject {
    @Published var caught: String?
    private var baseline = 0
    private var observer: NSObjectProtocol?

    func watch() {
        baseline = NSPasteboard.general.changeCount
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != baseline, let text = board.string(forType: .string) else { return }
        baseline = board.changeCount
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeKey(key) else { return }
        stop()
        caught = key
    }

    /// One word of 16 to 512 characters that is not a web address: what keys and tokens look like.
    static func looksLikeKey(_ text: String) -> Bool {
        (16...512).contains(text.count) && !text.contains(where: \.isWhitespace) && !text.lowercased().hasPrefix("http")
    }
}
