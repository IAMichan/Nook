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
| Chat apps | WhatsApp (phone link via GOWA or OpenWA, WhatsApp Desktop, chat helper), Messages (iMessage/SMS), Telegram, Slack, Teams, Snapchat (its website, `SnapchatBridge`), and the chat helper's networks (Signal, Instagram, Messenger, LinkedIn, X, Discord, Google Chat) | One shared inbox for every app: `InboxMessage`/`InboxThread`/`BridgedChat` (`ChatInbox.swift`) filled by a `ChatBridge` per app (WhatsApp's linked phone too: `WhatsAppGatewayBridge`), `ChatContract.swift` (abilities, actions), `ChatNoticeRules`, `ChatReceipts.swift`, `ChatTyping.swift`, `ChatBubble` + `ChatTranscript`, `ChatsEntry`/`ChatsTab`, one chat card (`AppModel+Chats.swift`) |
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
| Ticks on every message of yours | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (one tick, no receipts) | ✓ (two once read, from each member's read horizon) | ✓ (one tick, no receipts) |
| Who read it, in a group | ✓ (per member) | ✓ (`message.receipt`, Baileys engine) | – | ✓ (`getMessageViewers`) | ✓ (`seen` per person) | – (Slack keeps no read receipts) | ✓ (`consumptionhorizons`, where read receipts are on, up to 20 people) | – (the website does not say per person) |
| When they read it, in a private chat | ✓ (receipt arrival) | ✓ (receipt arrival) | ✓ (`date_read`) | ✓ (`getMessageReadDate`, unless either of you hides it) | ✓ (`seen` time) | – (Slack keeps no read receipts) | – (the read horizon says that, not when) | – (only "Opened" in the list, without a time) |
| Who is typing | ✓ (`chat_presence`, while a chat is open) | ✓ (`presence.update`, Baileys engine, while a chat is open) | – (not in the database) | ✓ (`updateChatAction`) | ✓ (bridgev2 `MarkTyping`) | – (only over a real-time socket Nook does not hold) | – (Graph does not say) | – (not read from the page yet) |
| Photo caption in the chat list | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (the list shows a status, not the message) |
| People by name, not by number | ✓ (your Contacts, then `/user/my/contacts`) | ✓ (your Contacts, then `/contacts`) | ✓ (Contacts) | ✓ (Telegram's names) | ✓ (the network's names) | ✓ | ✓ | ✓ (Snapchat's names) |
| Opened chat read from the app at once | ✓ (the chat's history) | ✓ (the chat's history) | ✓ | ✓ | ✓ (that chat read again) | ✓ | ✓ | ✓ |
| Notch card follows its chat live | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Shared links shown short (`[url](url)` → `site/path`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Edit, delete and info from the message's ⌄ menu (↑ in an empty field edits) | ✓ (when the gateway can) | ✓ (when the gateway can) | – from Nook (Messages lets no other app edit); an edit or unsend made in Messages shows (`date_edited`, `date_retracted`) | ✓ | ✓ (where the network allows it) | ✓ | ✓ | – (the website takes only new text) |
| Link previews and embeds (picture, video, sound, page card) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Calls shown as a call row (kind, who rang, how long; `ChatFormat.call`) | ✓ (the gateway's call line) | ✓ (the gateway's call line) | – (FaceTime calls are not in the chat database) | ✓ (`messageCall`) | ✓ (the bridge's call notice) | ✓ (huddles, `huddle_thread`) | ✓ (`Event/Call`, signed in through the website) | – (not read from the page yet) |
| Mark as unread, also a chat without messages in Nook yet | ✓ (`markedUnread`) | ✓ (`markedUnread`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read in the app or on the phone → read in Nook at once | ✓ (`readElsewhere`) | ✓ (`readElsewhere`) | ✓ (unread count) | ✓ (unread count) | ✓ (unread count, also without a new message) | ✓ (`client.counts`, signed in through the website; a pasted token: –) | ✓ (`readUntil`) | ✓ (the list's unread mark) |
| A chat Nook can only read says what is missing and links it (`ChatLimitsLine`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Emoji on messages | ✓ | ✓ | ✓ (tapbacks) | ✓ | ✓ | ✓ | ✓ | – (the website does not show them) |
| Who put each emoji there (tooltip, and a list on click) | ✓ (the chat's names) | ✓ (the chat's names) | ✓ (Contacts) | ✓ (`recent_sender_ids`, the last few) | ✓ (the chat's people) | ✓ | ✓ (Graph `displayName`; the web app by the names in the chat) | – (the website does not show emoji) |
| Your emoji sent as the app's own (never a placeholder there) | ✓ (any emoji) | ✓ (any emoji) | – (Messages takes no emoji from Nook) | ✓ (TDLib refuses what the chat does not allow) | ✓ (the bridge sends the emoji) | ✓ (Slack's names; one it lacks is refused with a clear message) | ✓ (`TeamsEmoji`, Microsoft's 3,114 keys incl. skin tones; one it lacks is refused) | – (the website takes no emoji) |
| Emoji that only a notification says ("Reacted 👍 to …"), put on that message | ✓ (WhatsApp on this Mac, whose database Nook does not read them from) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Someone's new emoji on your message as the chat list's line ("Reacted with 👍 to …", `ChatReactionNote`) | ✓ (the gateway's reaction event) | ✓ (the gateway's reaction event) | ✓ (tapbacks) | ✓ | ✓ | ✓ | ✓ | – (the website does not show emoji) |
| A message the app writes before its text (WhatsApp on this Mac) read again until it says something | ✓ (`waiting`, 10 minutes) | n/a (the gateways send finished messages) | n/a | n/a | n/a | n/a | n/a | n/a |
| Delete for me (any message; hidden in Nook on this Mac) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (also in Telegram, for you) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) |
| Real ticks on older messages | ✓ for receipts Nook received (kept on this Mac, `WAReceiptStore`) | ✓ same | ✓ (the database) | ✓ ("read up to") | ✓ (kept per person in `apps/chatd`) | – (Slack keeps no read receipts) | ✓ (read horizons, each time the chat is read) | – |
| More than one account (a business number, a second phone), its chats side by side and named by account | ✓ (a GOWA device per account, `WhatsAppAccounts`) | ✓ (an OpenWA session per account) | – (one Apple account on this Mac) | – (one TDLib login so far) | – (one login per network so far) | – (one workspace so far) | ✓ (every signed-in account) | – (one website session) |
| Its card in the notch answered in place: the field sends to the chat, a message can be quoted and get an emoji, a file opens, Read, Let Nook answer, Quiet, Hide | ✓ | ✓ | ✓ (text; no quotes or emoji, which Messages takes from no app) | ✓ | ✓ | ✓ | ✓ (text, quotes, emoji) | ✓ (text) |
| Notice rules: groups quiet unless they mention you, per chat automatic/always/never, hidden chats, a badge without quiet chats (`ChatNoticeRules`) | ✓ (also status updates and channels) | ✓ (same) | ✓ (groups; no mentions in the database) | ✓ (groups; mentions not read yet) | ✓ (groups; mentions not read yet) | ✓ (groups; mentions not read yet) | ✓ (groups; mentions not read yet) | ✓ (groups) |
| Answering (or Read on the card) also reads the chat in the app, a choice per app (`readsOnReply`) | ✓ | ✓ | – (Messages lets no other app mark read) | ✓ | ✓ | ✓ | ✓ | – (the website takes only new text) |
| Read in the app drops the chat's card still waiting in line (`onReadElsewhere`) | ✓ | ✓ | ✓ | ✓ | ✓ (unread count) | ✓ (`client.counts`, signed in through the website) | ✓ | ✓ |
| A video's first frame and a document's first page in its bubble (`ChatFileThumbnails`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (Nook fetches no files from Teams yet) | – (the website shows no files to Nook) |
| "@chat Name" brings up the chat's card | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Vote on a poll (`ChatAbilities.vote`) | – (GOWA has no vote call; whatsmeow has `BuildPollVote`, so it needs GOWA to add one) | ✓ (whatsapp-web.js engine; the Baileys engine answers 501 and polls are then only shown) | – (Messages has no polls another app can answer) | ✓ (`setPollAnswer`) | ✓ WhatsApp and Signal (`PollHandlingNetworkAPI`); – the other networks, whose connectors take no votes | – (no polls) | – (no polls) | – (no polls) |
| Pin, mute and archive the chat in its app | ✓ pin, archive; – mute (GOWA has no call; whatsmeow has `BuildMute`) | ✓ (`/chats/pin`, `/chats/mute`, `/chats/archive`) | – (Messages lets no other app) | ✓ | ✓ | – (only through Slack's own web-client methods, not built) | – (no chat pin or mute Nook can reach; hiding needs a Graph write scope) | – (the website offers none) |
| An action the app refused says why (under the field or as a toast), never a silent success | ✓ | ✓ | ✓ | ✓ (every request is tagged, `act`) | ✓ | ✓ | ✓ | ✓ |
| Nook answers in the chat when you ask it to (`chat_send`, through `chatRoute` and `runInChat`; you approve the text first) | ✓ (also `whatsapp_send`) | ✓ (also `whatsapp_send`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| A lost sign-in is told apart from a passing failure (reading waits, Settings asks to sign in again) | ✓ (the gateway's status) | ✓ (the gateway's status) | – (no sign-in; Full Disk Access) | ✓ (TDLib's state) | ✓ (the helper's status) | ✓ (`SlackData.signedOut`) | ✓ (`TeamsData.signInGone`, a passing refusal keeps the sign-in) | ✓ |

### One inbox for every app

Every chat Nook shows lives in one place, the shared inbox (`ChatInbox`), whichever app it is in: the Chats tab, the
cards in the notch, search, the iPhone companion and what Nook reads (`chat_inbox`) all read it, and one rule says which
chats show (`ChatCaptureService.isShown`: the app is on, you did not hide the chat, and WhatsApp comes from one place at
a time). Each app's bridge only translates what its app keeps into it. WhatsApp through the linked phone is one of them
(`WhatsAppGatewayBridge`): its link keeps WhatsApp's own state (the gateway, the JIDs, each person's emoji, each voter's
choice, each member's ticks) and `WhatsAppExport` turns it into the shared shape. Its messages are kept in memory only, as
they always were (`BridgedChat.ephemeral`: `chat-inbox.json` holds WhatsApp's chats without their messages), and the
link tells which message is news (live, not history, not a catch-up after the Mac slept: `ChatNewsBridge`).

A chat its app knows by an id of its own (`BridgedChat.chatID`, WhatsApp's chat key across accounts) is kept by it, so a
new name never splits it and two chats with one name stay two. Ids from before (`wa|<key>`) are read as the new ones
(`ChatIDMigration`) wherever something was kept under them (hidden messages, drafts, the chat opened last).

### One way for every action

Everything you do in a chat from Nook goes through `AppModel.runInChat` (`App/AppModel+ChatSend.swift`), whichever app
the chat is in: sending text or an item, an emoji, a vote, an edit, a deletion, "Mark as read in <app>", pinning, muting
and archiving. It first checks what holds for every app (`ChatAction.refusal` in `ChatContract.swift`): the chat's
`ChatAbilities` take the action (the same list the Chats tab draws its buttons from, so a button and its action never
disagree), there is text where text is sent, and a message changed or deleted for everyone is yours. Then the app's
bridge does only its own translation. Afterwards the chat is read again from its app at once (`readSoon`; the WhatsApp
gateways push their changes themselves), and the action is logged under one name per action (`chat_send`,
`chat_react`, `chat_vote`…) with the app in the entry. A new chat app adds a case to `ChatRoute`, its line in
`chatAbilities`, and its call in each action's `switch`; nothing else.

"Mark as read in <app>" reads the chat in Nook at once, and counts it as read in the app (and logs it so) only once the
app took it. When the app refuses, a toast says why.

An open chat is the same for every app too (`App/AppModel+ChatOpen.swift`): opening it reads it from its app, the
pointer resting on it fetches what the click needs, scrolling back asks its app for older messages, a file opens from this
Mac or its app, and the chat is online where its app needs that to say who types (WhatsApp). The Chats tab never asks
where a chat came from.

Which chats reach you is the same for every app (`ChatNoticeRules`, kept by `ChatNoticeRulesStore`, chosen in each app's
sheet in Settings › Chats with `ChatAppNoticeRows`, and on a chat's card with Quiet and Hide): a kind of chat can stay
quiet (groups, unless a message mentions you; WhatsApp's status updates and channels too), each chat can be automatic,
always or never, and a hidden chat never shows, counts or reaches you until you show it again. The first launch took over
what Settings › WhatsApp kept, for every linked account. WhatsApp's link sorts its gateway's messages by the same rules.

In Settings › Chats every linked account is a `ChatLinkedAccountRow`: one rule (`ChatAccountHealth`) says whether it
reads, is off in Nook, fails for a passing reason, or is signed out (`ChatCaptureService.bridgeSignedOut`, per account
for Teams), and only the last offers "Sign in again". WhatsApp's accounts keep their own list (`WhatsAppAccountList`):
a linked phone's state is the gateway's, not a read's.

### One way for every read

Every bridge reads on its own turn, side by side (`ChatCaptureService.pollBridges`): a slow web service never holds up
a quick one. The chat helper reads a chat again when the chat list moved past the newest message it got
(`ChatServiceData.isBehind`, up to three times), so a chat's row never shows an older message than the chat itself.

A read that fails waits longer each time, the same for every bridge (`ChatBackoff`): a minute (or the bridge's own
interval when that is longer), then twice as long after each failure in a row, up to a quarter of an hour. A
notification or a send from Nook does not cut that short; signing in again does. A bridge counts as reading an app only
while it is ready (signed in, its app not taken over by the chat helper), so its last good read never hides the app's
notifications or keeps the helper from reading that app. Cursors move only once a whole read worked (Messages' rows and
tapbacks), and a later read follows every page newer than the last one it read (Slack, five pages of 30), so a busy
chat loses nothing between two reads. Uploads and long fetches (a file sent, the helper scrolling back) run on
`ConnectorHTTP.transferSession`, so they are not cut off after 20 seconds.

Every app also gets what is certain from later messages (`ChatReceipts.filled` and `filledReaders`). Someone who read
a later message of yours read the earlier ones too. In a private chat, their message after yours means yours reached
them. Neither WhatsApp gateway keeps receipts. So a message whose receipts came while Nook was not running (or before
it was linked) shows only what those rules prove.

WhatsApp can link more than one account through the same gateway (Settings › Chats › WhatsApp › Add account): each
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
| Effort level | ✓ (`--effort`) | ✓ | ? | ? | ? | ? | ? | ? |
| The agent's own `/` commands (`/compact`, `/goal`) | ✓ | ✓ | ? (ACP `available_commands_update` is not read yet) | ? (same) | ? (same) | ? (same) | ? (same) | ? (same) |
| A model or mode picked in an open session counts from the next message | ✓ (live) | ✓ (`turn/start`) | ✓ (`session/set_config_option` or `session/set_model`, answered before the prompt) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Model list | ✓ | ✓ | ✓ | – (typed name) | – (typed name) | – (typed name) | – (typed name) | – (typed name) |
| Nook's tools (bridge) | ✓ (`claude mcp add`) | ✓ (`codex mcp add`) | ✓ | ✓ (`session/new` `mcpServers`) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Progress in the notch from a terminal (hooks) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (no hooks) | – (no hooks) |
| Past sessions from disk | ✓ | ✓ | ✓ | ✓ | – (`session/load`) | – (same) | – (same) | – (same) |
| Resume a past session | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (`session/load`) |
| Several accounts side by side | ✓ (`CLAUDE_CONFIG_DIR`) | ✓ (`CODEX_HOME`) | – (no home variable) | – (same) | – (same) | – (same) | – (same) | – (same) |
| Subscription limits | ✓ | ✓ | – | ✓ | – | – | – | – |
| A turn that failed on an expired login offers to sign in again (`AgentSignInFailure`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (signs in itself, in its next session) |
| Signing in happens in your browser, without a Terminal window, and the failed turn runs again afterwards (`AgentKind.browserLoginArguments`) | ✓ (`claude auth login`) | ✓ (`codex login`) | – (Terminal: `gemini` only signs in in its interactive screen) | ✓ (over ACP) | – (Terminal: `opencode auth login` asks which provider) | ✓ (`cursor-agent login`) | – (Terminal: `grok` only signs in in its interactive screen) | – (signs in itself, in its next session) |

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

- **Mentions outside WhatsApp.** "Groups quiet unless they mention you" knows a mention only where the app says it:
  WhatsApp's gateways do (`mentionsMe`). Telegram (`contains_unread_mention`), Slack (`<@you>` in the text) and Teams
  (a message's mentions) say it too, but their bridges do not read it yet, so a quiet group of theirs stays quiet.

Add an item here when a change cannot reach every member yet.
