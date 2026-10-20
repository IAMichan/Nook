import AppKit

/// The general pasteboard, for the copy buttons and menu items.
enum Pasteboard {
    /// Replaces what is on the pasteboard with `text`.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
