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
                                         "skype", "threema", "beeper", "dm'?s?"])
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
        var lines = ["Chats from the user's other chat apps (collected from their notifications on this Mac; Telegram, Instagram, Messenger, Signal and more): read one with chat_inbox. Nook cannot answer in these apps."]
        if !unread.isEmpty { lines.append("Unread chats:\n" + ChatInbox.overview(unread, limit: 6)) }
        return lines
    }

    var tools: [ToolSpec] {
        guard isActive else { return [] }
        return [
            ToolSpec(
                name: "chat_inbox",
                description: "The user's chats in Telegram, Instagram, Messenger, Signal, Messages, Slack, Discord and other chat apps, as their notifications on this Mac showed them (only what came in while Nook collected, at most 30 days; not the user's own replies). Without chat: the recent chats, newest first, with unread counts and the newest message. With chat (a name, optionally with app): that chat's messages.",
                schema: ["type": "object", "properties": [
                    "chat": ["type": "string", "description": "The chat's name (a person or group). Leave empty for the overview."],
                    "app": ["type": "string", "description": "Only this app: telegram, instagram, messenger, signal, messages, slack, discord, teams…"],
                    "limit": ["type": "integer", "description": "How many messages of the chat (default 20, at most 50)."]
                ]],
                kind: .read,
                summarize: { input in
                    let chat = AppData.string(input["chat"]).trimmingCharacters(in: .whitespaces)
                    return chat.isEmpty ? tr("chats.tool.overview") : tr("chats.tool.chat", chat)
                },
                tag: { _ in ("", .neutral) },
                run: { input in
                    let inbox = ChatCaptureService.shared.inbox
                    let app = AppData.string(input["app"]).trimmingCharacters(in: .whitespaces).lowercased()
                    let appID = app.isEmpty ? nil : (MessagingApps.all.first { $0.id == app || $0.name.lowercased() == app }?.id ?? app)
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
}
