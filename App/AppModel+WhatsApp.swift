import SwiftUI

/// WhatsApp in the notch: a new message shows as a card with the last lines of the chat and a field to answer. What you
/// type there goes to that chat when you press Return (your own words, your own click); "Let Nook answer" hands the
/// chat to Nook, who proposes an answer as a plan you approve.
extension AppModel {
    static let whatsAppCardPrefix = "whatsapp-"

    func startWhatsApp() {
        WhatsAppLink.shared.onMessage = { [weak self] chat in self?.presentWhatsApp(chat) }
        WhatsAppLink.shared.start()
    }

    func presentWhatsApp(_ chat: String) {
        let link = WhatsAppLink.shared
        guard WhatsAppSettings.notify, let conversation = link.inbox.conversations[chat],
              let last = conversation.messages.last(where: { !$0.fromMe }) else { return }
        let token = Self.whatsAppCardPrefix + chat
        viewModel.register("\(token)#read") { link.markRead(chat) }
        viewModel.register("\(token)#nook") { [weak self] in
            guard let self else { return }
            link.markRead(chat)
            self.ask(tr("whatsapp.card.nookPrompt", conversation.name))
        }
        viewModel.register("\(token)#mute") { link.ignore(chat) }

        // The lines before the newest one, as small facts above it; each label is unique (time and who).
        var earlier: [Fact] = []
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        for message in conversation.messages.dropLast().suffix(3) {
            let who = message.fromMe ? tr("whatsapp.you") : (message.senderName.isEmpty ? conversation.name : message.senderName)
            var label = "\(time.string(from: message.date)) · \(who)"
            while earlier.contains(where: { $0.label == label }) { label += "\u{200B}" }
            earlier.append(Fact(label: label, value: Self.whatsAppText(message)))
        }
        let sender = conversation.isGroup && !last.senderName.isEmpty ? "\(conversation.name) · \(last.senderName)" : conversation.name
        let unread = conversation.unread > 1 ? " · \(tr("whatsapp.card.unread", conversation.unread))" : ""
        let title = Self.whatsAppText(last)
        let card = NookCard(
            id: token,
            mood: .remind,
            context: "WhatsApp · \(sender)\(unread)",
            title: title,
            detail: earlier.isEmpty ? .none : .facts(earlier),
            primary: CardAction(label: tr("whatsapp.card.read"), outcome: .callback("\(token)#read", "")),
            secondary: CardAction(label: tr("button.later"), outcome: .dismiss),
            contentHeight: 150 + CGFloat(earlier.count) * 22 + CGFloat(min(title.count / 46, 4)) * 22,
            input: true,
            inputPrompt: tr("whatsapp.card.answer", conversation.name),
            extra: [CardAction(label: tr("whatsapp.card.nook"), outcome: .callback("\(token)#nook", "")),
                    CardAction(label: tr("whatsapp.card.mute"), outcome: .callback("\(token)#mute", ""))],
            escape: CardAction(label: "", outcome: .dismiss)
        )
        if viewModel.hasCard(id: token) { viewModel.updateCard(card) } else { viewModel.present(card) }
    }

    /// Return in a WhatsApp card's field: the text goes to that chat as typed.
    func replyWhatsApp(_ text: String, chat: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let name = try await WhatsAppLink.shared.send(reply, to: chat)
                self.store.audit(tool: "whatsapp_send", args: name, result: "verstuurd")
                self.viewModel.dismissCard(id: Self.whatsAppCardPrefix + chat)
                self.viewModel.finish(tr("whatsapp.sent", name))
            } catch {
                self.viewModel.present(self.errorCard(error.localizedDescription))
            }
        }
    }

    static func whatsAppText(_ message: WAMessage) -> String {
        [WhatsAppRecipients.label(message.media), message.text.isEmpty ? nil : message.text]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// Flow, dictation anywhere: its clean-up runs on Nook's own brain.
extension AppModel {
    func startFlow() {
        FlowDictation.shared.rewrite = { [weak self] system, text, timeout in
            await self?.brain.rewrite(system: system, prompt: text, timeout: timeout)
        }
        FlowDictation.shared.refresh()
    }
}
