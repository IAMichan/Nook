import WebKit

/// whatsapp_send through WhatsApp Web open next to the chat, for when no phone is linked through a gateway: the user
/// approves the recipient and the exact text in the plan, then Nook opens that chat in the pane, types the text and sends
/// it (see `WhatsAppWeb` for the script and its checks). "@open chat Jan" opens a chat there the same way.
extension EmbeddedAppStore {
    /// WhatsApp Web is the app beside the chat and has loaded, so a message can go through it.
    var whatsAppWebOpen: Bool {
        guard let current, !current.isMacApp, let webView else { return false }
        return WhatsAppWeb.isWhatsAppWeb(webView.url ?? current.url)
    }

    /// Sends `text` to the chat named `chat` in WhatsApp Web beside the chat; returns the chat's name as WhatsApp shows it.
    func sendWhatsApp(_ text: String, to chat: String) async throws -> String {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whatsAppWebOpen, let webView else { throw NookError(tr("whatsapp.web.notOpen")) }
        guard !message.isEmpty, !name.isEmpty else { throw NookError(tr("whatsapp.web.failed", "text")) }
        guard message.count <= WhatsAppWeb.maxText else { throw NookError(tr("whatsapp.web.tooLong", WhatsAppWeb.maxText)) }
        // The chat and the text go in as arguments, never into the script's source.
        let result = try await webView.callAsyncJavaScript(WhatsAppWeb.sendScript, arguments: ["name": name, "text": message],
                                                           in: nil, contentWorld: .defaultClient)
        switch WhatsAppWeb.outcome(result) {
        case .sent(let sent): return sent.isEmpty ? name : sent
        case .signedOut: throw NookError(tr("whatsapp.web.signedOut"))
        case .notFound: throw NookError(tr("whatsapp.web.notFound", name))
        case .ambiguous(let names): throw NookError(tr("whatsapp.web.ambiguous", name, names.joined(separator: ", ")))
        case .draft(let found): throw NookError(tr("whatsapp.web.draft", found))
        case .notSent(let found): throw NookError(tr("whatsapp.web.notSent", found))
        case .failed(let step): throw NookError(tr("whatsapp.web.failed", step))
        case .opened: throw NookError(tr("whatsapp.web.failed", "answer"))
        }
    }

    /// Opens the chat named `chat` in WhatsApp Web beside the chat ("@open chat Jan"); returns its name as WhatsApp shows
    /// it. Right after "@open" the page is often still loading or syncing, so it keeps trying for a while.
    @discardableResult
    func openWhatsAppChat(_ chat: String) async throws -> String {
        let name = chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NookError(tr("whatsapp.open.notFound", name)) }
        let tries = 12
        for attempt in 1...tries {
            guard whatsAppWebOpen, let webView else { throw NookError(tr("whatsapp.web.notOpen")) }
            if webView.isLoading {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            // The name goes in as an argument, never into the script's source.
            let result = try await webView.callAsyncJavaScript(WhatsAppWeb.openScript, arguments: ["name": name],
                                                               in: nil, contentWorld: .defaultClient)
            switch WhatsAppWeb.outcome(result) {
            case .opened(let opened): return opened.isEmpty ? name : opened
            case .signedOut where attempt < tries: try await Task.sleep(nanoseconds: 1_500_000_000)
            case .signedOut: throw NookError(tr("whatsapp.open.signedOut", name))
            case .notFound: throw NookError(tr("whatsapp.open.notFound", name))
            case .ambiguous(let names): throw NookError(tr("whatsapp.open.ambiguous", name, names.joined(separator: ", ")))
            case .failed(let step): throw NookError(tr("whatsapp.open.failed", name, step))
            case .sent, .draft, .notSent: throw NookError(tr("whatsapp.open.failed", name, "answer"))
            }
        }
        throw NookError(tr("whatsapp.open.signedOut", name))
    }

    /// Offered only while WhatsApp Web is open beside the chat and no phone is linked (then the gateway's whatsapp_send
    /// is there instead).
    static var whatsAppWebTools: [ToolSpec] {
        guard shared.whatsAppWebOpen, !WhatsAppLink.shared.isConnected else { return [] }
        return [
            ToolSpec(
                name: "whatsapp_send",
                description: "Sends a WhatsApp message from the user's own account to an existing chat (a contact or group), through WhatsApp Web that is open next to the chat in Nook: Nook searches the chat by name, opens it, types the message and presses send. Use when the user asks to app, WhatsApp or message someone or a group. Write the message as the user would, in their language and tone, without a signature. The user sees the exact text and recipient and approves before anything is sent.",
                schema: ["type": "object", "properties": [
                    "to": ["type": "string", "description": "The chat's name as WhatsApp shows it: a contact or group, e.g. \"Doorsturen\"."],
                    "message": ["type": "string", "description": "The full text to send."]
                ], "required": ["to", "message"]],
                kind: .action,
                summarize: { input in
                    let to = AppData.string(input["to"]).trimmingCharacters(in: .whitespaces)
                    return "WhatsApp Web → \(to): \(AppData.string(input["message"]))"
                },
                tag: { _ in ("sends", .caution) },
                run: { input in
                    let name = try await EmbeddedAppStore.shared.sendWhatsApp(AppData.string(input["message"]), to: AppData.string(input["to"]))
                    return "WhatsApp message sent to \(name) through WhatsApp Web."
                }
            )
        ]
    }
}
