# Integration Parity

Nook connects to many things of the same kind: chat apps, coding agents, connectors, AI providers, WhatsApp gateways,
and the apps on each platform (macOS, the iPhone companion, Linux, Windows, Android). The user sees them as one product.
When something works for one of them, they expect it to work for all of them, in the same way and in the same place.

## The rule

**A change to one integration is a change to its whole family.** When you add or change a feature for one integration,
do the same for every other integration of that kind in the same change, or write down why it cannot be done.

1. **Find the family.** Look up the kind of integration in the table below and list all of its members.
2. **Build it once, in the shared shape.** Put the feature in the family's shared type or view, not in one member. Each
   member then only translates what its app says into that shape. Never fork the UI per app.
3. **Fill it in for every member.** Wire each member that can support the feature. Check each one's API, protocol, or
   local data. Do not assume a member cannot support a feature until you have checked.
4. **Say what is not possible.** If a member's app does not offer the information (for example, Slack has no read
   receipts), leave it out on purpose. Note it in the matrix below and in a comment at that member. Never show a guess
   as if it were the app's own word.
5. **Test the shared logic once, and each member's parsing.** Every member gets a test for how it reads its app's data
   into the shared shape.
6. **Update this file** when a family or a feature changes, so the next change starts from a true picture.

If the user asks for something "in WhatsApp", it still applies to every chat app. If they ask for something for Claude
Code, it still applies to every coding agent. Mention any member you could not do in your summary to the user.

## Families

| Family | Members | Shared shape (build features here) |
|---|---|---|
| Chat apps | WhatsApp (phone link via GOWA or OpenWA, WhatsApp Desktop, chat helper), Messages (iMessage/SMS), Telegram, Slack, Teams, and the chat helper's networks (Signal, Instagram, Messenger, LinkedIn, X, Discord, Google Chat) | `InboxMessage`/`InboxThread` (`ChatInbox.swift`), `ChatReceipts.swift`, `ChatTyping.swift`, `ChatBubble` + `ChatTranscript`, `ChatsEntry`/`ChatsTab` |
| WhatsApp gateways | GOWA, OpenWA | `WhatsAppProvider` (`WhatsAppProvider.swift`), `WAWebhookEvent` (`WhatsAppGateway.swift`) |
| Chat helper networks | every bridge in `apps/chatd` | `apps/chatd` (bridgev2 `MatrixAPI` in `matrix.go`, the `/v1` API, the `/v1/ws` live line) → `ChatServiceData` |
| Coding agents | Claude Code, Claude Desktop, Codex, Gemini CLI, Antigravity, Cursor, Copilot CLI, Muse Code, OpenCode, Amp, Hermes ([`AGENTS.md`](AGENTS.md)) | `AgentConfigInstaller`, the hook event protocol, the session rows in the notch |
| Connectors | everything registered with `SourceCatalog.register` | `SourceCatalog` (metadata, tools, aliases, intents) |
| AI providers | the providers behind the Brain | `AIProvider`, the single `prepareRun` pipeline |
| Platforms | `apps/macos`, `apps/ios`, `apps/linux`, `apps/windows`, `apps/android`, `apps/tauri` | `packages/protocol`, the companion protocol ([`COMPANION.md`](COMPANION.md)) |

## Chat feature matrix

`✓` = shown, `–` = the app does not say it (left out on purpose), `?` = not checked yet.

| Feature | WhatsApp (GOWA) | WhatsApp (OpenWA) | Messages | Telegram | Chat helper networks | Slack | Teams |
|---|---|---|---|---|---|---|---|
| Ticks on every message of yours | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (one tick, no receipts) | ✓ (one tick, no receipts) |
| Who read it, in a group | ✓ (per member) | ✓ (`message.receipt`, Baileys engine) | – | ✓ (`getMessageViewers`) | ✓ (`seen` per person) | – | – |
| When they read it, in a private chat | ✓ (receipt arrival) | ✓ (receipt arrival) | ✓ (`date_read`) | – (only "read up to") | ✓ (`seen` time) | – | – |
| Who is typing | ✓ (`chat_presence`, while a chat is open) | ✓ (`presence.update`, Baileys engine, while a chat is open) | – (not in the database) | ✓ (`updateChatAction`) | ✓ (bridgev2 `MarkTyping`) | – (only over a real-time socket Nook does not hold) | – (Graph does not say) |
| Photo caption in the chat list | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

While a WhatsApp chat is open in Nook, Nook tells WhatsApp this device is online, as WhatsApp Web does. Otherwise
WhatsApp sends no typing updates. While it is online, the phone may hold back its own notifications.

## Platforms and chats

The iPhone companion is the only other app with the Chats tab. It gets the same things as the Mac over the companion
protocol. The filled-in ticks come in each `InboxLine.ticks`. Who read it comes in `InboxLine.readers` and opens from
the ticks. Who is typing comes in `InboxChatDigest.typing` for the list and `CompanionResponse.inboxTyping` for the
open chat. The Linux, Windows, Android and Tauri apps have no chat inbox. If one gets one, it reads these same fields.

## Open gaps

None right now. Add an item here when a change cannot reach every member yet.
