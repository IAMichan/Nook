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
| Coding agents | Claude Code, Claude Desktop, Codex, Gemini CLI, Antigravity, Cursor, Grok, OpenCode, the ACP agents you add, Copilot CLI, Muse Code, Amp, Hermes ([`AGENTS.md`](AGENTS.md)) | `ProviderCapabilities` (`WorkspaceModels.swift`), `AgentModelMenu` (models, aliases, levels and effort per agent; an ACP agent you added by its profile), `AcpSessionSettings` and `AcpSessionCapabilities` (`AcpAgent.swift`), `AgentConfigInstaller`, the hook event protocol, the session rows in the notch; for sessions Nook runs, `AgentSignal`/`AgentTimeline` (`AgentTimeline.swift`); for sessions in a terminal, `AgentChatMessage`/`AgentToolStep` (`AgentTranscript.swift`) |
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
| Opened chat read from the app at once | ✓ (the chat's history) | ✓ (the chat's history) | ✓ | ✓ | ✓ (that chat read again) | ✓ | ✓ | ✓ |
| Notch card follows its chat live | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Shared links shown short (`[url](url)` → `site/path`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Edit, delete and info from the message's ⌄ menu (↑ in an empty field edits) | ✓ (when the gateway can) | ✓ (when the gateway can) | – (Messages lets no other app edit) | ✓ | ✓ (where the network allows it) | ✓ | ✓ | – (the website takes only new text) |
| Link previews and embeds (picture, video, sound, page card) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Calls shown as a call row (kind, who rang, how long; `ChatFormat.call`) | ✓ (the gateway's call line) | ✓ (the gateway's call line) | – (FaceTime calls are not in the chat database) | ✓ (`messageCall`) | ✓ (the bridge's call notice) | – (huddles are not messages) | – (Graph does not list calls in a chat) | – (not read from the page yet) |
| Mark as unread, also a chat without messages in Nook yet | ✓ (`markedUnread`) | ✓ (`markedUnread`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read in the app or on the phone → read in Nook at once | ✓ (`readElsewhere`) | ✓ (`readElsewhere`) | ✓ (unread count) | ✓ (unread count) | ✓ (unread count, also without a new message) | – (Nook reads no unread count from Slack) | ✓ (`readUntil`) | ✓ (the list's unread mark) |
| A chat Nook can only read says what is missing and links it (`ChatLimitsLine`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Emoji on messages | ✓ | ✓ | ✓ (tapbacks) | ✓ | ✓ | ✓ | ✓ | – (the website does not show them) |
| Who put each emoji there (tooltip, and a list on click) | ✓ (the chat's names) | ✓ (the chat's names) | ✓ (Contacts) | ✓ (`recent_sender_ids`, the last few) | ✓ (the chat's people) | ✓ | ✓ (Graph `displayName`; the web app by the names in the chat) | – (the website does not show emoji) |
| Your emoji sent as the app's own (never a placeholder there) | ✓ (any emoji) | ✓ (any emoji) | – (Messages takes no emoji from Nook) | ✓ (TDLib refuses what the chat does not allow) | ✓ (the bridge sends the emoji) | ✓ (Slack's names; one it lacks is refused with a clear message) | ✓ (`TeamsEmoji`, Microsoft's 3,114 keys incl. skin tones; one it lacks is refused) | – (the website takes no emoji) |
| Emoji that only a notification says ("Reacted 👍 to …"), put on that message | ✓ (WhatsApp on this Mac, whose database Nook does not read them from) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Someone's new emoji on your message as the chat list's line ("Reacted with 👍 to …", `ChatReactionNote`) | ✓ (the gateway's reaction event) | ✓ (the gateway's reaction event) | ✓ (tapbacks) | ✓ | ✓ | ✓ | ✓ | – (the website does not show emoji) |
| A message the app writes before its text (WhatsApp on this Mac) read again until it says something | ✓ (`waiting`, 10 minutes) | – | – | – | – | – | – | – |
| Delete for me (any message; hidden in Nook on this Mac) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (also in Telegram, for you) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) |
| Real ticks on older messages | ✓ for receipts Nook received (kept on this Mac, `WAReceiptStore`) | ✓ same | ✓ (the database) | ✓ ("read up to") | ✓ (kept per person in `apps/chatd`) | – | – | – |
| More than one account (a business number, a second phone), its chats side by side and named by account | ✓ (a GOWA device per account, `WhatsAppAccounts`) | ✓ (an OpenWA session per account) | – (one Apple account on this Mac) | – (one TDLib login so far) | – (one login per network so far) | – (one workspace so far) | ✓ (every signed-in account) | – (one website session) |

Every bridge reads on its own turn, side by side (`ChatCaptureService.pollBridges`): a slow web service never holds up
a quick one. The chat helper reads a chat again when the chat list moved past the newest message it got
(`ChatServiceData.isBehind`, up to three times), so a chat's row never shows an older message than the chat itself.

Every app also gets what is certain from later messages (`ChatReceipts.filled` and `filledReaders`). Someone who read
a later message of yours read the earlier ones too. In a private chat, their message after yours means yours reached
them. Neither WhatsApp gateway keeps receipts. So a message whose receipts came while Nook was not running (or before
it was linked) shows only what those rules prove.

WhatsApp can link more than one account through the same gateway (Settings › Connections › WhatsApp › Add account): each
account is a `WhatsAppLink` of its own, on its own GOWA device or OpenWA session (named after its `WAAccount` id), with
its own QR, webhook port (the first account's port plus its place in the list) and read marks. The rest of Nook knows a
chat by its key across accounts (`WAChatKey`): the first account's chats by their JID alone, so nothing kept from before
changes, another account's as `<account id>~<JID>`. `WhatsAppAccounts.route` finds the account and the JID again. The
choices per kind of chat and per chat hold in every account. WhatsApp on this Mac (its database) and the chat helper still
read one account each: the WhatsApp Business app for the Mac keeps its own database, which Nook does not read yet.

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
| Effort level | ✓ (`--effort`) | ✓ | ✓ (the session's `thought_level` config option, when it offers one; not in the headless fallback) | ✓ (same; a model listed per level is picked with the same control) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| The agent's own `/` commands (`/compact`, `/goal`) | ✓ | ✓ | ✓ (`available_commands_update`) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| A model or mode picked in an open session counts from the next message | ✓ (live) | ✓ (`turn/start`) | ✓ (`session/set_config_option` or `session/set_model`, answered before the prompt) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Model list | ✓ | ✓ | ✓ | ✓ (what its session lists, kept for the next one) | ✓ (same) | ✓ (same) | ✓ (`initialize`) | ✓ (same as OpenCode, per agent you added) |
| Nook's tools (bridge) | ✓ (`claude mcp add`) | ✓ (`codex mcp add`) | ✓ | ✓ (`session/new` `mcpServers`) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| One notice when a turn ends (`AgentStatusNotice`: the agent's logo, what the session is about, its last reply, changed lines; paced by `NoticePacer`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (sessions in Nook) | ✓ (same) |
| Progress in the notch from a terminal (hooks) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (no hooks) | – (no hooks) |
| Past sessions (`ProviderCapabilities.pastSessions`) | ✓ (disk) | ✓ (disk) | ✓ (disk, `.json` and from 0.33 `.jsonl`) | ✓ (disk) | ✓ (`session/list`) | ✓ (disk: `~/.cursor/chats` and `agent-transcripts`; its ACP server has no `session/list`) | ? (`session/list` when Grok offers it; not checked) | ✓ (`session/list` when the agent offers it) |
| Resume a past session | ✓ | ✓ | ✓ | ✓ (in the Antigravity app while it runs; otherwise in Nook, a new conversation that starts from its transcript) | ✓ | ✓ | ✓ | ✓ (`session/load`) |
| A conversation the agent no longer knows starts anew from a summary of the timeline, said in it | ? | ✓ (`thread/resume`) | ✓ (`session/load`) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Several accounts side by side | ✓ (`CLAUDE_CONFIG_DIR`) | ✓ (`CODEX_HOME`) | ✓ (`GEMINI_CLI_HOME`, Gemini CLI 0.25 and newer: the folder around an account's `.gemini`) | – (one Google sign-in per Antigravity; each Nook account keeps its own profile folder for its sessions) | – (same) | – (same) | – (same) | – (same) |
| Subscription limits | ✓ | ✓ | – | ✓ | – | – | – | – |
| A turn that failed on an expired login offers to sign in again (`AgentSignInFailure`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (signs in itself: `authenticate` with its first `authMethods` entry when a session asks for it) |
| Signing in happens in your browser, without a Terminal window, and the failed turn runs again afterwards (`AgentKind.browserLoginArguments`) | ✓ (`claude auth login`) | ✓ (`codex login`) | – (Terminal: `gemini` only signs in in its interactive screen) | ✓ (over ACP) | – (Terminal: `opencode auth login` asks which provider) | ✓ (`cursor-agent login`) | ✓ (`grok login`) | – (signs in itself: `authenticate` with its first `authMethods` entry when a session asks for it) |

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
| A read stops spinning once the agent moves on | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (`AcpOpenReads`: Antigravity 1.3.0 closes its `view_file` only at the end of the turn, without output) |

Sessions in a terminal are read from the agent's own transcript (`AgentTranscript`). Claude Code and Codex give
messages, thinking, steps with their outcome and output, compactions and errors. Gemini CLI's chat file gives messages,
thoughts and its `toolCalls` as the same steps (with outcome, output and the lines an edit changed).

Both kinds of session draw their conversation with the same views, so a session reads the same whichever agent runs it
and whether Nook or a terminal runs it: messages are `TranscriptUserMessage` and `TranscriptReply`
(`TranscriptMessage.swift`), the work between them `TranscriptWorkLine`, `TranscriptThought`, `TranscriptStepDetail`,
`TranscriptWorkGroup`, `TranscriptFold`, `TranscriptWorkingLine` and `TranscriptLiveLine` (`TranscriptWork.swift`). A
session Nook runs translates a tool call into the transcript's step with `AgentToolStep(event:)`; a new kind of row is
added to those views, never drawn by one side alone. The iPhone companion draws its conversations with the same rows
(`TranscriptViews.swift`): the Mac sends a session Nook runs and one in a terminal as the same `TimelineEntry`s (a step's
summary without its tool's name, a compaction marked `TimelineEntry.compacted`), and the phone groups steps under the
Mac's sentence ("Ran 3 commands and read 2 files"). The phone gets no thinking and no tool output, for either kind of
session.

A session's title is the name the agent gave it, when it gives one: Claude Code's `custom-title` lines (the Claude app
names every session, `/rename` too), Codex's `thread_name` in `session_index.jsonl`, and Antigravity's
`conversation_summaries.db`. Gemini CLI's chat files hold no name, so its sessions take their first prompt. A session Nook
takes over without either is named after its first question and then gets a written title (`generateTitle`), never the
folder name.

## Signing in

Every member of every family signs in without a key where its service offers that, and only falls back to a key where
it does not. Settings shows the sign-in as the way in and folds the key away under Advanced. Where a key is the only
way, its sheet has one button to the page that makes it, and `ClipboardKeyCatcher` picks the copied key up when you
come back to Nook, so you never paste it.

| Family | Signs in | Key or token only, and why |
|---|---|---|
| Connectors | GitHub (its login or the GitHub CLI), and through their own MCP sign-in (`MCPRemoteService`): Notion, Linear, Stripe, Vercel, Sentry, Jira & Confluence, Canva, Supabase, Neon, Hugging Face, Cal.com, Resend, GitLab.com. Any other MCP server on the web that offers OAuth signs in when added by its address (n8n, a self-hosted GitLab) | n8n's own API (self-hosted; its MCP address signs in instead), a self-hosted GitLab's merge requests in the notch, exchange keys in the portfolio (read-only keys are the exchanges' own way) |
| AI providers | Your own account through its coding agent (`AIProvider.cliCommand`), each locked down to answering only: Claude through Claude Code (`ClaudeCodeBrain`); ChatGPT through Codex, Google through Gemini CLI, xAI through Grok, Kimi through Kimi Code and Mistral through Vibe (`SubscriptionBrain`). OpenRouter (`OpenRouterSignIn`, its own OAuth page). On this Mac (built in, Ollama, LM Studio: nothing to sign in to) | The APIs themselves take keys only. DeepSeek has no login of its own; Qwen's login (Qwen OAuth) closed on 2026-04-15, its Coding Plan is a key. Pictures go along through Codex only; the others read them only as files, which stays off. Kimi Code and Vibe never search the web for Nook: their search tools are not documented, so all their tools stay off |
| Coding agents | every agent through its own login, in the browser where it has one (see the table above) | an API key per account stays possible under Advanced |
| Chat apps | WhatsApp (QR code), Teams and Slack (their websites), Snapchat (its website), Telegram (phone number and code), Messages (this Mac), the chat helper's networks | Telegram through TDLib in a build without the chat helper needs an api_id and api_hash, unless the build sets `NOOK_TELEGRAM_API_ID`; GIFs use Nook's own GIPHY key, a key of your own only avoids its limit |

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

Add an item here when a change cannot reach every member yet.
