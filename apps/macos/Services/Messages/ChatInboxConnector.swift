import SwiftUI

/// Settings › Connections › On your Mac › Chats: the switch for `ChatCaptureService` (off until you turn it on, since it
/// reads every notification macOS shows), and what Nook may read of the chats it collected: the unread ones as context,
/// and any chat with `chat_inbox`. Messages are untrusted text from other people, never instructions.
@MainActor
final class ChatInboxConnector: ContextSource {
    static let sourceID = "chats"

    let id = ChatInboxConnector.sourceID
    var title: String { tr("chats.source.title") }
    let symbol = "tray.full.fill"
    var accent: Color { NookTheme.blue }
    var iconDomain: String? { nil }
    private(set) var status = ConnectorStatus()

    private var capture: ChatCaptureService { ChatCaptureService.shared }

    init() {
        // Chat apps no other source stands for (Slack, Discord and Teams can have connectors of their own; "line" and "x"
        // are everyday words).
        SourceCatalog.register(SourceDescriptor(id: id, title: "Chats", kind: .builtIn), tools: ["chat_inbox"],
                               aliases: ["telegram", "instagram", "insta", "messenger", "signal", "snapchat", "viber", "wechat",
                                         "skype", "threema", "dm'?s?"])
    }

    var isActive: Bool { ConnectorToggle.isOn(id, default: false) }
    var refreshInterval: TimeInterval { 60 }

    func refresh() async {
        // The switch in Settings decides; the service follows it.
        if capture.enabled != isActive { capture.enabled = isActive }
        if isActive { await capture.poll() }
        switch capture.status {
        case .off:
            status = ConnectorStatus(state: .off, detail: tr("chats.source.detail"))
        case .needsAccess:
            status = ConnectorStatus(state: .error(tr("chats.capture.needsAccess")), errorKind: .auth)
        case .failed(let message):
            status = ConnectorStatus(state: .error(message))
        case .running:
            let inbox = capture.inbox
            status = ConnectorStatus(state: .ok, headline: tr("chats.source.count", inbox.threads.count),
                                     detail: tr("chats.source.detail"), updated: Date(), needsAttention: false)
        }
    }

    func contextLines() -> [String] {
        guard isActive, capture.status == .running else { return [] }
        let unread = capture.inbox.sorted.filter { $0.unread > 0 }
        var lines = ["Chats from the user's other chat apps (collected from their notifications on this Mac; Telegram, Instagram, Messenger, Signal and more): read one with chat_inbox, or find a message in all of them (the user's own sent ones too) with its query. Nook cannot answer in these apps."]
        if !unread.isEmpty { lines.append("Unread chats:\n" + ChatInbox.overview(unread, limit: 6)) }
        return lines
    }

    var tools: [ToolSpec] {
        guard isActive else { return [] }
        return [
            ToolSpec(
                name: "chat_inbox",
                description: "The user's chats in WhatsApp, Telegram, Instagram, Messenger, Signal, Messages, Teams, Slack, LinkedIn, Discord and other chat apps, as Nook has them: from each app Nook links, the user's own sent messages included (\"You\"); from an app Nook only reads notifications of, only what came in. With query: the messages in every chat that hold all its words, the user's own too, newest first. Without chat and query: the recent chats, newest first, with unread counts and the newest message. With chat (a name, optionally with app): that chat's messages.",
                schema: ["type": "object", "properties": [
                    "query": ["type": "string", "description": "Words to find in the messages of every chat, sent and received. Optional."],
                    "chat": ["type": "string", "description": "The chat's name (a person or group). Leave empty for the overview."],
                    "app": ["type": "string", "description": "Only this app: telegram, instagram, messenger, signal, messages, slack, discord, teams…"],
                    "limit": ["type": "integer", "description": "How many messages of the chat (default 20, at most 50)."]
                ]],
                kind: .read,
                summarize: { input in
                    let query = AppData.string(input["query"]).trimmingCharacters(in: .whitespaces)
                    if !query.isEmpty { return tr("chats.tool.search", query) }
                    let chat = AppData.string(input["chat"]).trimmingCharacters(in: .whitespaces)
                    return chat.isEmpty ? tr("chats.tool.overview") : tr("chats.tool.chat", chat)
                },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    let inbox = ChatCaptureService.shared.inbox
                    let app = AppData.string(input["app"]).trimmingCharacters(in: .whitespaces).lowercased()
                    let appID = app.isEmpty ? nil : (MessagingApps.app(named: app)?.id ?? app)
                    let query = AppData.string(input["query"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty {
                        let threads = (self?.everyChat() ?? inbox.sorted).filter { appID == nil || $0.app == appID }
                        let found = ChatInbox.search(threads, query: query)
                        return found.isEmpty ? "No message in the chats holds \"\(query)\"." : "Messages with \"\(query)\" (newest first):\n" + found
                    }
                    let chat = AppData.string(input["chat"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !chat.isEmpty else {
                        let threads = inbox.sorted.filter { appID == nil || $0.app == appID }
                        return threads.isEmpty ? "No chats collected yet." : "Recent chats (newest first):\n" + ChatInbox.overview(threads, limit: 20)
                    }
                    guard let thread = inbox.thread(named: chat, app: appID) else {
                        let names = inbox.sorted.prefix(12).map(\.name).joined(separator: ", ")
                        return "No collected chat is called \"\(chat)\". Recent chats: \(names.isEmpty ? "none" : names)."
                    }
                    let limit = min(max(Int(AppData.number(input["limit"]) ?? 20), 1), 50)
                    let appName = MessagingApps.app(id: thread.app)?.name ?? thread.app
                    return "\(appName) chat with \(thread.name):\n" + ChatInbox.transcript(thread, limit: limit)
                }
            )
        ]
    }

    /// Every chat Nook has, as the Chats tab lists them: the collected ones, and WhatsApp's through the linked phone
    /// unless the chat helper links WhatsApp (then its chats are among the collected ones).
    private func everyChat() -> [InboxThread] {
        var threads = capture.inbox.sorted.filter { capture.sources.isOn($0.app) }
        let link = WhatsAppLink.shared
        guard link.isConnected, !ChatHelper.linked("whatsapp") else { return threads }
        threads.removeAll { $0.app == "whatsapp" }
        for conversation in link.inbox.sorted where !link.filters.ignored.contains(conversation.id) {
            var names = link.memberIndex(conversation)
            let messages = conversation.messages.map { message in
                InboxMessage(id: message.id, sender: message.fromMe || !conversation.isGroup ? "" : names.name(message.sender),
                             text: AppModel.whatsAppText(message), date: message.date, fromMe: message.fromMe)
            }
            threads.append(InboxThread(id: "wa|" + conversation.id, app: "whatsapp", name: conversation.name, messages: messages))
        }
        return threads
    }
}
