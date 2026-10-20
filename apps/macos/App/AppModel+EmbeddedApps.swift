import SwiftUI

/// Apps inside Nook: "@open whatsapp" shows WhatsApp Web next to the chat, so you chat in the app itself and with Nook
/// about it side by side; "@open chat Jan" does the same and opens Jan's chat in it. "@close" puts it away again (it
/// stays signed in).
extension AppModel {
    /// Handles "@open …", "@whatsapp", "@open chat Jan" and "@close" from the chat. False when the text is no such command.
    func handleEmbeddedAppCommand(_ text: String) -> Bool {
        guard let command = EmbeddedAppCatalog.command(in: text) else { return false }
        chat.append(ChatMessage(role: .user, text: text))
        switch command {
        case .open(let app, let mode):
            let opened = openEmbeddedApp(app, mode: mode)
            chat.append(ChatMessage(role: .nook, text: openedMessage(opened.app, opened.mode, chosen: opened.chosen)))
        case .close:
            let title = EmbeddedAppStore.shared.current?.title
            Task { await closeEmbeddedApp() }
            chat.append(ChatMessage(role: .nook, text: title.map { tr("embedded.closed", $0) } ?? tr("embedded.nothingOpen")))
        case .chat(let name):
            openWhatsAppChat(name)
        case .unknown(let name):
            let names = EmbeddedAppCatalog.suggestions(for: name).map { "@open " + $0.title }.joined(separator: ", ")
            chat.append(ChatMessage(role: .nook, text: tr("embedded.unknown", name, names)))
        }
        showChat()
        return true
    }

    /// Opens `app` the way asked for, else the way you chose last time for it, else beside the chat. A way asked for is
    /// remembered when the app has more than one. `chosen`: the way came from you, now or before.
    @discardableResult
    func openEmbeddedApp(_ app: EmbeddedApp, mode: EmbeddedAppMode? = nil) -> (app: EmbeddedApp, mode: EmbeddedAppMode, chosen: Bool) {
        let wanted = mode ?? (app.isMacApp ? EmbeddedAppPreference.mode(for: app) : nil)
        let (target, way) = EmbeddedAppCatalog.resolve(app, mode: wanted)
        if mode != nil, EmbeddedAppCatalog.modes(for: target).count > 1 { EmbeddedAppPreference.remember(way, for: target) }
        if way == .window {
            // Outside Nook: the app itself in front, in its own window; nothing stays beside the chat.
            EmbeddedAppStore.shared.close()
            viewModel.embeddedAppOpen = false
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { _, _ in }
        } else {
            EmbeddedAppStore.shared.open(target)
            // One thing beside the chat at a time: the app takes the browser's place.
            viewModel.browserBesideChat = false
            viewModel.embeddedAppOpen = true
        }
        return (target, way, wanted != nil)
    }

    /// "@open chat Jan": WhatsApp opens next to the chat, the way you open it ("@open whatsapp"), with Jan's chat in it.
    /// In WhatsApp Web Nook searches the chat and clicks it; the Mac app opens a person's chat by their number (known
    /// from a linked phone), and otherwise you pick the chat there yourself. Nothing is typed or marked read.
    func openWhatsAppChat(_ name: String) {
        guard let whatsApp = EmbeddedAppCatalog.find("whatsapp") else { return }
        // A linked phone knows the chat's exact name and number; without one the name goes as typed.
        let target = WhatsAppLink.shared.resolve(name)
        let shown = target?.name ?? name
        let opened = openEmbeddedApp(whatsApp)
        switch opened.mode {
        case .web:
            chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.opening", shown)))
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await EmbeddedAppStore.shared.openWhatsAppChat(shown)
                } catch {
                    // Closed or switched away in the meantime: there is nothing left to tell.
                    guard EmbeddedAppStore.shared.current?.id == opened.app.id else { return }
                    self.chat.append(ChatMessage(role: .nook, text: error.localizedDescription))
                }
            }
        case .mirror, .window:
            guard let link = target.flatMap({ WAJID.appLink($0.jid) }) else {
                chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.pick", opened.app.title, shown)))
                break
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = opened.mode == .window
            NSWorkspace.shared.open([link], withApplicationAt: opened.app.url, configuration: configuration) { _, _ in }
            chat.append(ChatMessage(role: .nook, text: tr(opened.mode == .window ? "whatsapp.open.window" : "whatsapp.open.opened", shown)))
        }
    }

    /// Opens the app beside the chat another way, chosen at the top of its pane, and remembers that for next time.
    func switchEmbeddedApp(to mode: EmbeddedAppMode) {
        guard let current = EmbeddedAppStore.shared.current else { return }
        let opened = openEmbeddedApp(current, mode: mode)
        if opened.mode == .window {
            chat.append(ChatMessage(role: .nook, text: openedMessage(opened.app, opened.mode, chosen: true)))
        }
    }

    /// What Nook says after opening an app. Until you have chosen a way for an app that has more than one, it says how.
    private func openedMessage(_ app: EmbeddedApp, _ mode: EmbeddedAppMode, chosen: Bool) -> String {
        if mode == .window { return tr("embedded.openedWindow", app.title, app.title) }
        let opened = tr("embedded.opened", app.title)
        guard !chosen, EmbeddedAppCatalog.modes(for: app).count > 1 else { return opened }
        return opened + " " + tr("embedded.otherWays", app.title)
    }

    /// Puts the app away. `forget`: also signs out of it on this Mac.
    func closeEmbeddedApp(forget: Bool = false) async {
        if forget { await EmbeddedAppStore.shared.forget() } else { EmbeddedAppStore.shared.close() }
        viewModel.embeddedAppOpen = false
    }

    /// For the context: which app is open next to the chat, so "what does Arjan say?" is read from it.
    var embeddedAppContextLine: String? {
        guard let app = EmbeddedAppStore.shared.current else { return nil }
        var line = "Open next to the chat (inside Nook): \(app.title). Read what it shows with read_open_app when the user asks about it."
        if !EmbeddedAppStore.whatsAppWebTools.isEmpty {
            line += " WhatsApp messages to a contact or group go through it with whatsapp_send (the user approves the exact text first)."
        }
        return line
    }
}
