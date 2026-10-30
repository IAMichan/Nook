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
        SourceCatalog.register(SourceDescriptor(id: id, title: "Chats", kind: .builtIn), tools: ["chat_inbox", "chat_send"],
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
        let unread = capture.inbox.sorted.filter { $0.unread > 0 && capture.isShown($0) }
        var lines = ["Chats from the user's other chat apps (collected from their notifications on this Mac; Telegram, Instagram, Messenger, Signal and more): read one with chat_inbox, or find a message in all of them (the user's own sent ones too) with its query."]
        let writable = Self.writableApps()
        lines.append(writable.isEmpty ? "Nook cannot answer in these apps."
            : "Nook can answer in chats of \(writable.joined(separator: ", ")) with chat_send (the user approves the exact text first); chats of other apps are read only.")
        if !unread.isEmpty { lines.append("Unread chats:\n" + ChatInbox.overview(unread, limit: 6)) }
        return lines
    }

    /// The apps with at least one shown chat Nook can write in, by name: the same routes the Chats tab sends through.
    private static func writableApps() -> [String] {
        let capture = ChatCaptureService.shared
        var apps: [String] = []
        for thread in capture.inbox.sorted where capture.isShown(thread) && !apps.contains(thread.app) {
            if AppModel.shared.chatRoute(for: thread) != nil { apps.append(thread.app) }
        }
        return apps.map { MessagingApps.app(id: $0)?.name ?? $0 }
    }

    /// Nook reads the chats it has whenever it has any: those it collects, and a linked phone's WhatsApp chats, which
    /// come without collecting.
    var tools: [ToolSpec] {
        guard isActive || WhatsAppAccounts.shared.isConnected else { return [] }
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
                run: { input in
                    // Every chat that shows, the same way for every app (`ChatCaptureService.isShown`).
                    let capture = ChatCaptureService.shared
                    let inbox = capture.inbox
                    let shown = inbox.sorted.filter(capture.isShown)
                    let app = AppData.string(input["app"]).trimmingCharacters(in: .whitespaces).lowercased()
                    let appID = app.isEmpty ? nil : (MessagingApps.app(named: app)?.id ?? app)
                    let query = AppData.string(input["query"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty {
                        let threads = shown.filter { appID == nil || $0.app == appID }
                        let found = ChatInbox.search(threads, query: query)
                        return found.isEmpty ? "No message in the chats holds \"\(query)\"." : "Messages with \"\(query)\" (newest first):\n" + found
                    }
                    let chat = AppData.string(input["chat"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !chat.isEmpty else {
                        let threads = shown.filter { appID == nil || $0.app == appID }
                        return threads.isEmpty ? "No chats collected yet." : "Recent chats (newest first):\n" + ChatInbox.overview(threads, limit: 20)
                    }
                    guard let thread = inbox.thread(named: chat, app: appID, among: capture.isShown) else {
                        let names = shown.prefix(12).map(\.name).joined(separator: ", ")
                        return "No collected chat is called \"\(chat)\". Recent chats: \(names.isEmpty ? "none" : names)."
                    }
                    let limit = min(max(Int(AppData.number(input["limit"]) ?? 20), 1), 50)
                    let appName = MessagingApps.app(id: thread.app)?.name ?? thread.app
                    return "\(appName) chat with \(thread.name):\n" + ChatInbox.transcript(thread, limit: limit)
                }
            ),
            ToolSpec(
                name: "chat_send",
                description: "Sends a message from the user's own account to an existing chat in one of their chat apps (WhatsApp, Telegram, Slack, Teams, Messages, Instagram, Messenger, Signal…), the way the user would answer it in Nook's Chats tab. Use when the user asks to message or answer someone in a chat app. Write the message as the user would, in their language and tone, without a signature. A reply answers the chat's newest messages: read the chat first with chat_inbox, and when its newest message is days old, tell the user so instead of answering it as if it were new. The user sees the exact text and chat and approves before anything is sent.",
                schema: ["type": "object", "properties": [
                    "to": ["type": "string", "description": "The chat's name (a person or group) as chat_inbox shows it."],
                    "app": ["type": "string", "description": "The chat's app as chat_inbox shows it: whatsapp, telegram, slack, teams, messages, instagram… Give it whenever the chat's app is known."],
                    "message": ["type": "string", "description": "The full text to send."],
                ], "required": ["to", "message"]],
                kind: .action,
                summarize: { input in
                    let to = AppData.string(input["to"]).trimmingCharacters(in: .whitespaces)
                    let app = AppData.string(input["app"]).trimmingCharacters(in: .whitespaces)
                    let name = app.isEmpty ? tr("chats.source.title") : (MessagingApps.app(named: app)?.name ?? app)
                    return tr("chats.tool.send", name, to, AppData.string(input["message"]))
                },
                tag: { _ in ("sends", .caution) },
                run: { input in
                    let capture = ChatCaptureService.shared
                    let app = AppData.string(input["app"]).trimmingCharacters(in: .whitespaces).lowercased()
                    let appID = app.isEmpty ? nil : (MessagingApps.app(named: app)?.id ?? app)
                    let chat = AppData.string(input["to"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let text = AppData.string(input["message"])
                    guard let thread = capture.inbox.thread(named: chat, app: appID, among: capture.isShown) else {
                        let names = capture.inbox.sorted.filter(capture.isShown).prefix(12).map(\.name).joined(separator: ", ")
                        throw NookError("No chat is called \"\(chat)\". Recent chats: \(names.isEmpty ? "none" : names).")
                    }
                    let appName = MessagingApps.app(id: thread.app)?.name ?? thread.app
                    // The same route and checks as the Chats tab (`runInChat`): what Nook can only read is said, not sent.
                    guard let route = AppModel.shared.chatRoute(for: thread) else {
                        throw NookError(tr("chats.tool.readOnly", appName, thread.name))
                    }
                    try await AppModel.shared.sendChatText(text, route: route, chat: thread.name, thread: thread.id)
                    return "\(appName) message sent to \(thread.name)."
                }
            )
        ]
    }
}
