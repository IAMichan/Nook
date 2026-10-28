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

`AgentParityTests` holds coding agents to this. A check for one agent by name (`provider == .claude`) fails the test
when a file gets more of them than it has today. Give the feature a field in `ProviderCapabilities` or an exhaustive
`switch` over `RunProvider`/`AgentKind` instead, so every agent has to answer for it. Only when another agent's app
cannot offer it, raise that file's number in the test and write the gap in the feature matrix below. Every agent also
needs a column in that matrix.

## Families

| Family | Members | Shared shape (build features here) |
|---|---|---|
| Chat apps | WhatsApp (phone link via GOWA or OpenWA, WhatsApp Desktop, chat helper), Messages (iMessage/SMS), Telegram, Slack, Teams, Snapchat (its website, `SnapchatBridge`), and the chat helper's networks (Signal, Instagram, Messenger, LinkedIn, X, Discord, Google Chat) | `InboxMessage`/`InboxThread` (`ChatInbox.swift`), `ChatReceipts.swift`, `ChatTyping.swift`, `ChatBubble` + `ChatTranscript`, `ChatsEntry`/`ChatsTab` |
| WhatsApp gateways | GOWA, OpenWA | `WhatsAppProvider` (`WhatsAppProvider.swift`), `WAWebhookEvent` (`WhatsAppGateway.swift`) |
| Chat helper networks | every bridge in `apps/chatd` | `apps/chatd` (bridgev2 `MatrixAPI` in `matrix.go`, the `/v1` API, the `/v1/ws` live line) → `ChatServiceData` |
| Coding agents | Claude Code, Claude Desktop, Codex, Gemini CLI, Antigravity, Cursor, Grok, OpenCode, the ACP agents you add, Copilot CLI, Muse Code, Amp, Hermes ([`AGENTS.md`](AGENTS.md)) | `ProviderCapabilities` (`WorkspaceModels.swift`), `AgentConfigInstaller`, the hook event protocol, the session rows in the notch; for sessions Nook runs, `AgentSignal`/`AgentTimeline` (`AgentTimeline.swift`); for sessions in a terminal, `AgentChatMessage`/`AgentToolStep` (`AgentTranscript.swift`) |
| Connectors | everything registered with `SourceCatalog.register` | `SourceCatalog` (metadata, tools, aliases, intents) |
| AI providers | the providers behind the Brain | `AIProvider`, the single `prepareRun` pipeline |
| Platforms | `apps/macos`, `apps/ios`, `apps/linux`, `apps/windows`, `apps/android`, `apps/tauri` | `packages/protocol`, the companion protocol ([`COMPANION.md`](COMPANION.md)) |

## Chat feature matrix

`✓` = shown, `–` = the app does not say it (left out on purpose), `?` = not checked yet.

| Feature | WhatsApp (GOWA) | WhatsApp (OpenWA) | Messages | Telegram | Chat helper networks | Slack | Teams | Snapchat |
|---|---|---|---|---|---|---|---|---|
| Ticks on every message of yours | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (one tick, no receipts) | ✓ (one tick, no receipts) | ✓ (one tick, no receipts) |
| Who read it, in a group | ✓ (per member) | ✓ (`message.receipt`, Baileys engine) | – | ✓ (`getMessageViewers`) | ✓ (`seen` per person) | – | – | – (the website does not say per person) |
| When they read it, in a private chat | ✓ (receipt arrival) | ✓ (receipt arrival) | ✓ (`date_read`) | – (only "read up to") | ✓ (`seen` time) | – | – | – (only "Opened" in the list, without a time) |
| Who is typing | ✓ (`chat_presence`, while a chat is open) | ✓ (`presence.update`, Baileys engine, while a chat is open) | – (not in the database) | ✓ (`updateChatAction`) | ✓ (bridgev2 `MarkTyping`) | – (only over a real-time socket Nook does not hold) | – (Graph does not say) | – (not read from the page yet) |
| Photo caption in the chat list | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (the list shows a status, not the message) |
| People by name, not by number | ✓ (your Contacts, then `/user/my/contacts`) | ✓ (your Contacts, then `/contacts`) | ✓ (Contacts) | ✓ (Telegram's names) | ✓ (the network's names) | ✓ | ✓ | ✓ (Snapchat's names) |
| Real ticks on older messages | ✓ for receipts Nook received (kept on this Mac, `WAReceiptStore`) | ✓ same | ✓ (the database) | ✓ ("read up to") | ✓ (kept per person in `apps/chatd`) | – | – | – |

Every app also gets what is certain from later messages (`ChatReceipts.filled` and `filledReaders`). Someone who read
a later message of yours read the earlier ones too. In a private chat, their message after yours means yours reached
them. Neither WhatsApp gateway keeps receipts. So a message whose receipts came while Nook was not running (or before
it was linked) shows only what those rules prove.

While a WhatsApp chat is open in Nook, Nook tells WhatsApp this device is online, as WhatsApp Web does. Otherwise
WhatsApp sends no typing updates. While it is online, the phone may hold back its own notifications.

## Coding agent features

What each coding agent can do in Nook. `✓` = works, `–` = the agent does not offer it (left out on purpose),
`?` = not checked yet. A new feature for Claude Code adds a row here with every column filled in. A `?` is work to do:
check the agent's protocol before you write `–`.

| Feature | Claude Code | Codex | Gemini CLI | Antigravity | OpenCode | Cursor | Grok | ACP agents |
|---|---|---|---|---|---|---|---|---|
| Runs as a session in Nook | ✓ | ✓ (app-server) | ✓ (ACP) | ✓ (ACP) | ✓ (ACP) | ✓ (ACP) | ✓ (ACP) | ✓ |
| Asks you for permission | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Plan mode | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| A message during a turn changes it | ✓ (native) | ✓ (`turn/steer`) | ✓ (interrupt and restart) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Cost of a turn | ✓ | – | – | ✓ (when the agent sends it) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Context window meter | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Fork keeps the conversation | ✓ (`--fork-session`) | – (from a summary) | – (from a summary) | – (same) | – (same) | – (same) | – (same) | – (same) |
| Fork from an earlier turn | ✓ | – | – | – | – | – | – | – |
| Going back also rolls back the conversation | ✓ | ✓ (`thread/rollback`) | – (only the files) | – (same) | – (same) | – (same) | – (same) | – (same) |
| Effort level | ✓ (`--effort`) | ✓ | ? | ? | ? | ? | ? | ? |
| The agent's own `/` commands (`/compact`, `/goal`) | ✓ | ✓ | ? (ACP `available_commands_update` is not read yet) | ? (same) | ? (same) | ? (same) | ? (same) | ? (same) |
| Model list | ✓ | ✓ | ✓ | – (typed name) | – (typed name) | – (typed name) | – (typed name) | – (typed name) |
| Nook's tools (bridge) | ✓ (`claude mcp add`) | ✓ (`codex mcp add`) | ✓ | ✓ (`session/new` `mcpServers`) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Progress in the notch from a terminal (hooks) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (no hooks) | – (no hooks) |
| Past sessions from disk | ✓ | ✓ | ✓ | ✓ | – (`session/load`) | – (same) | – (same) | – (same) |
| Resume a past session | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (`session/load`) |
| Several accounts side by side | ✓ (`CLAUDE_CONFIG_DIR`) | ✓ (`CODEX_HOME`) | – (no home variable) | – (same) | – (same) | – (same) | – (same) | – (same) |
| Subscription limits | ✓ | ✓ | – | ✓ | – | – | – | – |

## Coding agent timeline

How a session's work reaches its timeline. Sessions Nook runs itself go through one path: each provider's handler only
translates its own output into `AgentSignal`s, and `AgentTimeline` writes them by the same rules for every agent (one
answer and one thought streaming at a time, a tool call is one row from start to end, nothing stays running after the
turn). Add a provider by translating into those signals, never by writing `RunEvent`s for text, thinking or tools
yourself.

| Feature | Claude Code | Codex (app-server) | Codex (exec) | Gemini CLI (ACP) | Gemini CLI (headless) | ACP agents (OpenCode, Cursor, Grok, Antigravity…) |
|---|---|---|---|---|---|---|
| Answer streams live | ✓ | ✓ | – (only whole messages) | ✓ | ✓ | ✓ |
| Thinking streams live | ✓ | ✓ | – (only whole reasoning) | ✓ | – (its stream has no thoughts) | ✓ (when the agent sends them) |
| Tool input in the row | ✓ | ✓ (also MCP and dynamic tools) | ✓ (also MCP) | ✓ | ✓ | ✓ |
| Tool output in the row | ✓ | ✓ (commands live, MCP results) | ✓ (commands, MCP results) | ✓ | ✓ | ✓ |
| Files a call changed | ✓ (Edit/Write) | ✓ (`fileChange`) | ✓ (`file_change`) | ✓ (call paths) | ✓ (replace/write_file) | ✓ (call paths) |

Sessions in a terminal are read from the agent's own transcript (`AgentTranscript`). Claude Code and Codex give
messages, thinking, steps with their outcome and output, compactions and errors. Gemini CLI's chat file gives messages,
thoughts and its `toolCalls` as the same steps (with outcome, output and the lines an edit changed).

A session's title is the name the agent gave it, when it gives one: Claude Code's `custom-title` lines (the Claude app
names every session, `/rename` too), Codex's `thread_name` in `session_index.jsonl`, and Antigravity's
`conversation_summaries.db`. Gemini CLI's chat files hold no name, so its sessions take their first prompt. A session Nook
takes over without either is named after its first question and then gets a written title (`generateTitle`), never the
folder name.

## Platforms and chats

The iPhone companion is the only other app with the Chats tab. It gets the same things as the Mac over the companion
protocol. The filled-in ticks come in each `InboxLine.ticks`. Who read it comes in `InboxLine.readers` and opens from
the ticks. Who is typing comes in `InboxChatDigest.typing` for the list and `CompanionResponse.inboxTyping` for the
open chat. The Linux, Windows, Android and Tauri apps have no chat inbox. If one gets one, it reads these same fields.

## Open gaps

- **Snapchat** is read from Snapchat for Web's page (`SnapchatWebData`), not from a service: Snapchat has none, and no
  bridgev2 connector for it exists. It shows the chat list and the messages of chats you load in Nook, and answers with
  text. Files, emoji, edits, deletions, pinning, muting, archiving, read receipts and typing are not offered for it
  (`ChatAbilities(send: true)`), and its messages carry the time Nook first saw them, since the website shows none.
- **CI logs of GitLab merge requests.** A GitHub check's steps and log open in Nook (`CICheckLogView` on the Mac,
  `CheckLog.svelte` in `apps/tauri`). A watched GitLab merge request still opens its pipelines page in the browser:
  Nook does not read GitLab job traces yet.

- **The GitHub dashboard in Chats (Tauri).** Pull requests and reviews sorted by what needs you, issues assigned to you,
  approving, commenting and asking for changes, and the merge rights check exist for GitHub only. GitLab merge requests
  are still only watched and opened in the browser; Nook has no GitLab review or merge actions yet.

- **Coding agents over ACP: effort and the agent's own `/` commands.** Claude Code and Codex offer an effort level and
  their `/compact` and `/goal` in the `/` list. ACP agents announce their commands in `available_commands_update` and
  their options in the session's config options; `AcpMapper` reads neither yet.

Add an item here when a change cannot reach every member yet.
