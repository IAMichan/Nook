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
| Chat apps | WhatsApp (phone link via GOWA or OpenWA, WhatsApp Desktop, chat helper), Messages (iMessage/SMS), Telegram, Slack, Teams, Snapchat (its website, `SnapchatBridge`), Mail (every account in the Mail app, `MailBridge`; Outlook, Gmail, Spark and Proton Mail through their notifications), and the chat helper's networks (Signal, Instagram, Messenger, LinkedIn, X, Discord, Google Chat) | One shared inbox for every app: `InboxMessage`/`InboxThread`/`BridgedChat` (`ChatInbox.swift`) filled by a `ChatBridge` per app (WhatsApp's linked phone too: `WhatsAppGatewayBridge`), `ChatContract.swift` (abilities, actions), `ChatNoticeRules`, `ChatReceipts.swift`, `ChatTyping.swift`, `ChatBubble` + `ChatTranscript`, `ChatsEntry`/`ChatsTab`, one chat card (`AppModel+Chats.swift`) |
| WhatsApp gateways | GOWA, OpenWA | `WhatsAppProvider` (`WhatsAppProvider.swift`), `WAWebhookEvent` (`WhatsAppGateway.swift`) |
| Chat helper networks | every bridge in `apps/chatd` | `apps/chatd` (bridgev2 `MatrixAPI` in `matrix.go`, the `/v1` API, the `/v1/ws` live line) → `ChatServiceData` |
| Coding agents | Claude Code, Claude Desktop, Codex, Gemini CLI, Antigravity, Cursor, Grok, OpenCode, the ACP agents you add, Copilot CLI, Muse Code, Amp, Hermes ([`AGENTS.md`](AGENTS.md)) | `ProviderCapabilities` (`WorkspaceModels.swift`), `AgentModelMenu` (models, aliases, levels and effort per agent; an ACP agent you added by its profile), `AcpSessionSettings` and `AcpSessionCapabilities` (`AcpAgent.swift`), `AgentConfigInstaller`, the hook event protocol, the session rows in the notch; for sessions Nook runs, `AgentSignal`/`AgentTimeline` (`AgentTimeline.swift`); for sessions in a terminal, `AgentChatMessage`/`AgentToolStep` (`AgentTranscript.swift`) |
| Connectors | everything registered with `SourceCatalog.register` | `SourceCatalog` (metadata, tools, aliases, intents) |
| AI providers | the providers behind the Brain | `AIProvider`, the single `prepareRun` pipeline |
| Platforms | `apps/macos`, `apps/ios`, `apps/linux`, `apps/windows`, `apps/android`, `apps/tauri` | `packages/protocol`, the companion protocol ([`COMPANION.md`](COMPANION.md)) |

## Chat feature matrix

`✓` = shown, `–` = the app does not say it (left out on purpose), `?` = not checked yet.

| Feature | WhatsApp (GOWA) | WhatsApp (OpenWA) | Messages | Telegram | Chat helper networks | Slack | Teams | Snapchat | Mail (Mail app) |
|---|---|---|---|---|---|---|---|---|---|
| Ticks on every message of yours | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (one tick, no receipts) | ✓ (two once read, from each member's read horizon) | ✓ (one tick, no receipts) | ✓ (one tick once it is in Sent; mail keeps no read receipts) |
| Who read it, in a group | ✓ (per member) | ✓ (`message.receipt`, Baileys engine) | – | ✓ (`getMessageViewers`) | ✓ (`seen` per person) | – (Slack keeps no read receipts) | ✓ (`consumptionhorizons`, where read receipts are on, up to 20 people) | – (the website does not say per person) | – (mail keeps no read receipts) |
| When they read it, in a private chat | ✓ (receipt arrival) | ✓ (receipt arrival) | ✓ (`date_read`) | ✓ (`getMessageReadDate`, unless either of you hides it) | ✓ (`seen` time) | – (Slack keeps no read receipts) | – (the read horizon says that, not when) | – (only "Opened" in the list, without a time) | – (mail keeps no read receipts) |
| Who is typing | ✓ (`chat_presence`, while a chat is open) | ✓ (`presence.update`, Baileys engine, while a chat is open) | – (not in the database) | ✓ (`updateChatAction`) | ✓ (bridgev2 `MarkTyping`) | – (only over a real-time socket Nook does not hold) | – (Graph does not say) | – (not read from the page yet) | – (mail has none) |
| Photo caption in the chat list | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (the list shows a status, not the message) | – (Nook reads no attachments from Mail yet) |
| People by name, not by number | ✓ (your Contacts, then `/user/my/contacts`) | ✓ (your Contacts, then `/contacts`) | ✓ (Contacts) | ✓ (Telegram's names) | ✓ (the network's names) | ✓ | ✓ | ✓ (Snapchat's names) | ✓ (the name in the sender's address) |
| Opened chat read from the app at once | ✓ (the chat's history) | ✓ (the chat's history) | ✓ | ✓ | ✓ (that chat read again) | ✓ | ✓ | ✓ | ✓ (Mail read again) |
| Notch card and the chat open in the Chats tab follow their chat live (its app read at least every 20 s while the card is up or waits, or the chat is open, `ChatCaptureService.watching`, `openChat`) | ✓ (live) | ✓ (live) | ✓ (every 2 s) | ✓ (every 3 s) | ✓ (live line, else every 10 s) | ✓ (every 20 s, else 60 s) | ✓ (every 20 s, else 60 s) | ✓ (every 20 s, else 30 s) | ✓ (Mail read again at once on its notification, else every 20 s, else 60 s) |
| Shared links shown short (`[url](url)` → `site/path`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Edit, delete and info from the message's ⌄ menu (↑ in an empty field edits) | ✓ (when the gateway can) | ✓ (when the gateway can) | – from Nook (Messages lets no other app edit); an edit or unsend made in Messages shows (`date_edited`, `date_retracted`) | ✓ | ✓ (where the network allows it) | ✓ | ✓ | – (the website takes only new text) | – (sent mail cannot be changed) |
| Message menu on right-click (the same as the ⌄ menu: `MessageMenuItems`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (a mail chat shows its own thread view) |
| Forward a message to other chats and groups (`ChatForward`, `AppModel.forwardChatMessage`; text to every chat Nook writes in, a file only where the chat takes its kind) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (text, and files Slack takes) | ✓ (text only: Teams takes no files from Nook) | ✓ (text only: the website takes only text) | – as a source (a mail chat shows its own thread view, with its own Forward); ✓ as a target, text only |
| Link previews and embeds (picture, video, sound, page card) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (Nook reads no attachments from Mail yet) |
| Calls shown as a call row (kind, who rang, how long; `ChatFormat.call`) | ✓ (the gateway's call line) | ✓ (the gateway's call line) | – (FaceTime calls are not in the chat database) | ✓ (`messageCall`) | ✓ (the bridge's call notice) | ✓ (huddles, `huddle_thread`) | ✓ (`Event/Call`, signed in through the website) | – (not read from the page yet) | – (no calls) |
| Mark as unread, also a chat without messages in Nook yet | ✓ (`markedUnread`) | ✓ (`markedUnread`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read in the app or on the phone → read in Nook at once, its waiting card and macOS notification gone | ✓ (`readElsewhere`) | ✓ (the phone's chat list counting nothing new, `WAInbox.readInGateway`; within five minutes) | ✓ (unread count) | ✓ (unread count) | ✓ (unread count, also without a new message) | ✓ (`client.counts`, signed in through the website; a pasted token: –) | ✓ (`readUntil`) | ✓ (the list's unread mark) | ✓ (read status) |
| A chat Nook can only read says what is missing and links it (`ChatLimitsLine`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Emoji on messages | ✓ | ✓ | ✓ (tapbacks) | ✓ | ✓ | ✓ | ✓ | – (the website does not show them) | – (no emoji) |
| Who put each emoji there (tooltip, and a list on click) | ✓ (the chat's names) | ✓ (the chat's names) | ✓ (Contacts) | ✓ (`recent_sender_ids`, the last few) | ✓ (the chat's people) | ✓ | ✓ (Graph `displayName`; the web app by the names in the chat) | – (the website does not show emoji) | – (no emoji) |
| Your emoji sent as the app's own (never a placeholder there) | ✓ (any emoji) | ✓ (any emoji) | – (Messages takes no emoji from Nook) | ✓ (TDLib refuses what the chat does not allow) | ✓ (the bridge sends the emoji) | ✓ (Slack's names; one it lacks is refused with a clear message) | ✓ (`TeamsEmoji`, Microsoft's 3,114 keys incl. skin tones; one it lacks is refused) | – (the website takes no emoji) | – (no emoji) |
| Emoji that only a notification says ("Reacted 👍 to …"), put on that message | ✓ (WhatsApp on this Mac, whose database Nook does not read them from) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (no emoji) |
| Someone's new emoji on your message as the chat list's line ("Reacted with 👍 to …", `ChatReactionNote`) | ✓ (the gateway's reaction event) | ✓ (the gateway's reaction event) | ✓ (tapbacks) | ✓ | ✓ | ✓ | ✓ | – (the website does not show emoji) | – (no emoji) |
| A message the app writes before its text (WhatsApp on this Mac) read again until it says something | ✓ (`waiting`, 10 minutes) | n/a (the gateways send finished messages) | n/a | n/a | n/a | n/a | n/a | n/a | n/a |
| Delete for me (any message; hidden in Nook on this Mac) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (also in Telegram, for you) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) | ✓ (Nook only) |
| Real ticks on older messages | ✓ for receipts Nook received (kept on this Mac, `WAReceiptStore`) | ✓ same | ✓ (the database) | ✓ ("read up to") | ✓ (kept per person in `apps/chatd`) | – (Slack keeps no read receipts) | ✓ (read horizons, each time the chat is read) | – | – (mail keeps no read receipts) |
| More than one account (a business number, a second phone), its chats side by side and named by account | ✓ (a GOWA device per account, `WhatsAppAccounts`) | ✓ (an OpenWA session per account) | – (one Apple account on this Mac) | – (one TDLib login so far) | ✓ (every login of a network; each chat named by the login it was bridged for, a group by the logins in it) | – (one workspace so far) | ✓ (every signed-in account) | – (one website session) | ✓ (every account in the Mail app: iCloud, Gmail, Outlook and Exchange, Yahoo, IMAP and POP, each chat named by its account) |
| Its card in the notch answered in place: the field sends to the chat, a message can be quoted and get an emoji, a file opens, Read, Let Nook answer, Quiet, Hide | ✓ | ✓ | ✓ (text; no quotes or emoji, which Messages takes from no app) | ✓ | ✓ | ✓ | ✓ (text, quotes, emoji) | ✓ (text) | ✓ (text, sent as a reply from the chat's account) |
| Notice rules: groups quiet unless they mention you, per chat automatic/always/never, hidden chats, a badge without quiet chats (`ChatNoticeRules`) | ✓ (also status updates and channels) | ✓ (same) | ✓ (groups; no mentions in the database) | ✓ (groups; mentions not read yet) | ✓ (groups; mentions not read yet) | ✓ (groups; mentions not read yet) | ✓ (groups; mentions not read yet) | ✓ (groups) | ✓ (no groups; newsletters and notifications are its channels, quiet by default) |
| Answering (or Read on the card) also reads the chat in the app, a choice per app (`readsOnReply`) | ✓ | ✓ | – (Messages lets no other app mark read) | ✓ | ✓ | ✓ | ✓ | – (the website takes only new text) | ✓ |
| Read in the app drops the chat's card still waiting in line (`onReadElsewhere`) | ✓ | ✓ | ✓ | ✓ | ✓ (unread count) | ✓ (`client.counts`, signed in through the website) | ✓ | ✓ | ✓ (read status) |
| A video's first frame and a document's first page in its bubble (`ChatFileThumbnails`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (Nook fetches no files from Teams yet) | – (the website shows no files to Nook) | – (no attachments yet) |
| A picture sent as a document shows as a photo, and a photo still on its way as a photo tile, not a file row (`ChatMedia.shownKind`, `BubbleMedia.photoComing`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (Nook fetches no files from Teams yet) | – (the website shows no files to Nook) | – (Nook reads no attachments from Mail yet) |
| "@chat Name" brings up the chat's card | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Vote on a poll (`ChatAbilities.vote`) | – (GOWA has no vote call; whatsmeow has `BuildPollVote`, so it needs GOWA to add one) | ✓ (whatsapp-web.js engine; the Baileys engine answers 501 and polls are then only shown) | – (Messages has no polls another app can answer) | ✓ (`setPollAnswer`) | ✓ WhatsApp and Signal (`PollHandlingNetworkAPI`); – the other networks, whose connectors take no votes | – (no polls) | – (no polls) | – (no polls) | – (no polls) |
| Pin, mute and archive the chat in its app | ✓ pin, archive; – mute (GOWA has no call; whatsmeow has `BuildMute`) | ✓ (`/chats/pin`, `/chats/mute`, `/chats/archive`) | – (Messages lets no other app) | ✓ | ✓ | – (only through Slack's own web-client methods, not built) | – (no chat pin or mute Nook can reach; hiding needs a Graph write scope) | – (the website offers none) | – (Mail lets no other app pin, mute or archive a conversation) |
| An action the app refused says why (under the field or as a toast), never a silent success | ✓ | ✓ | ✓ | ✓ (every request is tagged, `act`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Nook answers in the chat when you ask it to (`chat_send`, through `chatRoute` and `runInChat`; you approve the text first) | ✓ (also `whatsapp_send`) | ✓ (also `whatsapp_send`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (`chat_send`, as a reply through Mail) |
| A lost sign-in is told apart from a passing failure (reading waits, Settings asks to sign in again) | ✓ (the gateway's status) | ✓ (the gateway's status) | – (no sign-in; Full Disk Access) | ✓ (TDLib's state) | ✓ (the helper's status) | ✓ (`SlackData.signedOut`) | ✓ (`TeamsData.signInGone`, a passing refusal keeps the sign-in) | ✓ | – (no sign-in: Mail's own accounts; a refused Automation permission says how to give it) |
| Search everything (⌘K) finds a message in the whole history, not only the newest ones the inbox keeps (`ChatSearchBridge`) | ✓ (every message the linked accounts hold, plus WhatsApp on this Mac's database when it is installed) | ✓ (same) | ✓ (the whole database, as `search_messages`) | ✓ (`searchMessages` on Telegram's servers) | – (the helper has no search call yet: the newest messages Nook keeps) | ✓ (`search.messages`; a pasted token needs search:read) | – (no search Nook can reach without a Graph search scope: the newest messages Nook keeps) | – (the website has no search) | – (not yet: the newest messages Nook keeps; `search_mail` searches Mail for Nook) |

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

### Mail

Mail is a chat app like the others. `MailBridge` reads the Mail app on this Mac, and with it every account Mail holds,
whatever kind: iCloud, Gmail, Outlook and Exchange, Yahoo, any IMAP or POP account. Each person you write with is one
chat per account (`MailChatData.chatID`, `<account>~<address>`): their mail from the account's inbox, yours from its
Sent mailbox, each message as its subject in bold over the start of its own text (the quoted earlier mail left out,
`MailChatData.text`). With more than one account each chat is named by its account, as WhatsApp's are. Newsletters and
notifications (`MailChatData.isAutomated`) are the app's channels and stay quiet by default (`ChatNoticeRules`).

Nook reads Mail only after you linked it, in Settings › Chats › Mail or from Mail's empty list in the Chats tab (the
first read asks for Automation), and only while Mail is open, as the Mail connector does: it never starts Mail in the
background on its own. Linking it, or "Read Mail now" while Mail is closed, starts Mail out of sight once, so the first
chats show at once. A read in which not one account answered says why instead of showing an empty list. An answer goes out through Mail
(`MailSender`) as a reply to the chat's newest mail from the chat's account; "Mark as read" sets Mail's read status,
which tells the server. A mail chat shows as mail, not as bubbles (`MailThreadView`): a card per mail with its headers, attachments and whole
text (read from Mail when it opens, `MailBridge.message`), the quoted mail folded away. Reply goes to the field under it;
Reply all and Forward, and New mail in a mail app's list, write in the pane beside the list (`MailComposeView`), from
any address of any account, sent through Mail after your click and logged as `send_mail`. Mail apps Nook cannot read itself (Outlook for Mac, Gmail and Outlook on the web, Spark, Proton
Mail) are members by their notifications: `ChatCapture.mailNotice` reads the subject from them the same way. Mail has no
emoji, edits, polls, typing or read receipts another app can reach, and Nook reads no attachments from it yet.

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
app took it. When the app refuses, a toast says why; so does an app that has no message of the chat to mark (a Telegram
chat only its notifications brought, a Teams chat without a message Nook knows), instead of claiming it was read. What
the app is told is what you saw when you clicked: a message that came in while the call went stays new. A chat you
marked unread by hand (`InboxThread.markedUnread`) stays unread until you read it, whatever a lagging or windowed count
of its app says at its next read. A chat that an app names twice is read with its twin (`ChatInbox.twins`), so the badge
does not keep counting the one the tab hides. WhatsApp's linked phone keeps its chats in the tab through a short moment
its gateway does not answer (`WhatsAppLink.holdsChats`, ten minutes at most).

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
interval when that is longer), then twice as long after each failure in a row, up to a quarter of an hour. A bridge that
reads a database on this Mac (`ChatBridge.readsLocally`: Messages, WhatsApp on this Mac) starts at five seconds after a
passing failure (the app held its lock), and at a minute without Full Disk Access. A notification or a send from Nook
does not cut that short; signing in again does. A database the app kept locked past the wait is read without its
write-ahead log, where the newest rows may still be (`AppDatabase.read`, `complete`): Messages, WhatsApp on this Mac and
the notifications then read again at their next turn, also when the database did not change since, so a message still
in the log never waits for the app's next write. A bridge counts as reading an app only
while it is ready (signed in, its app not taken over by the chat helper), so its last good read never hides the app's
notifications or keeps the helper from reading that app. Cursors move only once a whole read worked (Messages' rows and
tapbacks), and a later read follows every page newer than the last one it read (Slack, five pages of 30), so a busy
chat loses nothing between two reads. Uploads and long fetches (a file sent, the helper scrolling back) run on
`ConnectorHTTP.transferSession`, so they are not cut off after 20 seconds.

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

A linked phone's messages come in on the gateway's webhook the moment they arrive. Without a webhook for five minutes,
Nook asks the gateway every ten seconds; with one, it still asks once a minute (`WhatsAppLink.safetyPollGap`), since a
webhook that keeps bringing ticks and typing may still have dropped a message.

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
| MCP steps read by server and tool ("GitHub › Create issue"); the Claude app's computer-use tools by what they do on your screen (`ScreenAction`), asking for control in amber | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| One notice when a turn ends (`AgentStatusNotice`: the agent's logo, what the session is about, its last reply, changed lines; paced by `NoticePacer`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (sessions in Nook) | ✓ (same) |
| Progress in the notch from a terminal (hooks) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | – (no hooks) | – (no hooks) |
| Past sessions (`ProviderCapabilities.pastSessions`) | ✓ (disk) | ✓ (disk) | ✓ (disk, `.json` and from 0.33 `.jsonl`) | ✓ (disk) | ✓ (`session/list`) | ✓ (disk: `~/.cursor/chats` and `agent-transcripts`; its ACP server has no `session/list`) | ? (`session/list` when Grok offers it; not checked) | ✓ (`session/list` when the agent offers it) |
| Resume a past session | ✓ | ✓ | ✓ | ✓ (in the Antigravity app while it runs; otherwise in Nook, a new conversation that starts from its transcript) | ✓ | ✓ | ✓ | ✓ (`session/load`) |
| A session Nook runs shows the turns written outside Nook (the agent's own app or terminal, also while it works there), with their steps (`TranscriptFollow`) | ✓ (the Claude app too) | ✓ | ✓ | ✓ (messages and thinking; its transcript has no steps) | – (no transcript on disk) | ? (from `agent-transcripts`; not checked) | – (same as OpenCode) | – (same) |
| A conversation the agent no longer knows starts anew from a summary of the timeline, said in it | ? | ✓ (`thread/resume`) | ✓ (`session/load`) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) | ✓ (same) |
| Several accounts side by side | ✓ (`CLAUDE_CONFIG_DIR`) | ✓ (`CODEX_HOME`) | ✓ (`GEMINI_CLI_HOME`, Gemini CLI 0.25 and newer: the folder around an account's `.gemini`) | – (one Google sign-in per Antigravity; each Nook account keeps its own profile folder for its sessions) | – (same) | – (same) | – (same) | – (same) |
| Subscription limits | ✓ | ✓ | – | ✓ (`retrieveUserQuotaSummary`: a 5-hour and a weekly window per model group, shown like Claude's with reset time and pace; the per-model list of `fetchAvailableModels` only for accounts without that summary) | – | – | – | – |
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
- **Mail** is read from the Mail app (`MailBridge`), every account in it, while Mail is open. Opening attachments in Nook (their names show; they open in Mail), scrolling back
  past the newest 60 inbox and 40 sent messages per account, and Outlook for Mac's or a web mailbox's own accounts (they
  come in by their notifications only; Nook answers them in a new mail through the Mail app) are not there yet.
- **CI logs of GitLab merge requests.** A GitHub check's steps and log open in Nook (`CICheckLogView` on the Mac,
  `CheckLog.svelte` in `apps/tauri`). A watched GitLab merge request still opens its pipelines page in the browser:
  Nook does not read GitLab job traces yet.
- **The Actions page for GitLab.** A GitHub repository's workflow runs (CI, a promote, a release), their jobs and logs,
  re-run and cancel are on the Actions page (`ActionsPanel` on the Mac, `views/agents/actions` in `apps/tauri`). A
  GitLab project's pipelines are not listed there yet: Nook reads no GitLab pipelines API.

- **The GitHub dashboard in Chats (Tauri).** Pull requests and reviews sorted by what needs you, issues assigned to you,
  approving, commenting and asking for changes, and the merge rights check exist for GitHub only. GitLab merge requests
  are still only watched and opened in the browser; Nook has no GitLab review or merge actions yet.

- **Mentions outside WhatsApp.** "Groups quiet unless they mention you" knows a mention only where the app says it:
  WhatsApp's gateways do (`mentionsMe`). Telegram (`contains_unread_mention`), Slack (`<@you>` in the text) and Teams
  (a message's mentions) say it too, but their bridges do not read it yet, so a quiet group of theirs stays quiet.

- **Searching the whole chat history from Search everything** (`ChatSearchBridge`) reaches Messages, WhatsApp (this
  Mac's database and what the linked phone brought), Telegram and Slack. The chat helper's networks, Teams, Snapchat and
  Mail are searched in the newest messages Nook keeps of each chat (`ChatInbox.keep`) only: the helper has no search call
  yet, Teams' search needs a Graph scope Nook does not ask for, Snapchat's website has none, and Mail's search goes
  through AppleScript, too slow for every keystroke.

Add an item here when a change cannot reach every member yet.
