import SwiftUI

/// Apps inside Nook: "@open whatsapp" shows WhatsApp Web next to the chat, so you chat in the app itself and with Nook
/// about it side by side. "@close" puts it away again (it stays signed in).
extension AppModel {
    /// Handles "@open …", "@whatsapp" and "@close" from the chat. False when the text is no such command.
    func handleEmbeddedAppCommand(_ text: String) -> Bool {
        guard let command = EmbeddedAppCatalog.command(in: text) else { return false }
        chat.append(ChatMessage(role: .user, text: text))
        switch command {
        case .open(let app):
            openEmbeddedApp(app)
            chat.append(ChatMessage(role: .nook, text: tr("embedded.opened", app.title)))
        case .close:
            let title = EmbeddedAppStore.shared.current?.title
            Task { await closeEmbeddedApp() }
            chat.append(ChatMessage(role: .nook, text: title.map { tr("embedded.closed", $0) } ?? tr("embedded.nothingOpen")))
        case .unknown(let name):
            let names = EmbeddedAppCatalog.suggestions(for: name).map { "@open " + $0.title }.joined(separator: ", ")
            chat.append(ChatMessage(role: .nook, text: tr("embedded.unknown", name, names)))
        }
        showChat()
        return true
    }

    func openEmbeddedApp(_ app: EmbeddedApp) {
        EmbeddedAppStore.shared.open(app)
        viewModel.embeddedAppOpen = true
    }

    /// Puts the app away. `forget`: also signs out of it on this Mac.
    func closeEmbeddedApp(forget: Bool = false) async {
        if forget { await EmbeddedAppStore.shared.forget() } else { EmbeddedAppStore.shared.close() }
        viewModel.embeddedAppOpen = false
    }

    /// For the context: which app is open next to the chat, so "what does Arjan say?" is read from it.
    var embeddedAppContextLine: String? {
        guard let app = EmbeddedAppStore.shared.current else { return nil }
        return "Open next to the chat (inside Nook): \(app.title). Read what it shows with read_open_app when the user asks about it."
    }
}
