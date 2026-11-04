# Nook Companion (iPhone)

**Nook Companion** is a lightweight iPhone app that shows which coding-agent sessions on your Mac need your attention, letting you **approve or deny tool calls, answer questions, send follow-up messages, and stop sessions**. With a current Nook on the Mac it can also **start new agent sessions, follow a session's whole conversation, and chat with Nook itself**. It communicates directly with Nook on your Mac over your local Wi-Fi network (or Tailscale/VPN) and, only when you turn it on, through a relay that passes sealed bytes it cannot read (see *Away from Home*). It keeps a live connection while it is open (see *Staying Connected*).

The phone sees two kinds of sessions:

- **Sessions Nook runs (Workspace):** approve or deny, answer questions, send messages, and stop them.
- **Agents running in a terminal on your Mac** (through their hooks, e.g. Claude Code in Terminal or iTerm) and requests through Nook's workspace bridge: they appear in the list and send push notifications for approvals, questions, and finished or failed turns. Approvals can be denied, and low-risk ones allowed, from the phone or straight from the notification; questions and messages are answered in the terminal (`apps/macos/Services/Companion/CompanionAgents.swift`).

## Starting from the phone

**Today** opens with three quick actions: **New session** (a coding agent, the New session sheet on the Agents tab),
**Ask Nook** (a new chat with Nook) and **Answer a chat** (the Chats tab), each with what is going on there (sessions at
work, unread chats). An action the Mac does not allow this phone, or that the Mac is too old for, stays in sight dimmed
with a lock and says why and what to change when tapped (`QuickActionBlock`), so nothing you look for quietly
disappears; the Agents tab's New session button does the same.

In **Chats**, *Can answer* lists the chats Nook writes in for you; a chat you can only read says so in the list (*Read
only*) and, at its end, how to link its app in Nook › Settings › Chat apps to answer it from the phone.

While a session Nook runs works, its composer offers **Steer now** (into the running turn, as the Mac's composer
steers) or **After this turn** (in line); the choice is remembered (`CompanionRequest.steer`, `SessionDigest.canSteer`,
`CompanionFeature.steer`). An approval or a question is docked right above the composer, in sight however far up you
read. The Agents list has search and a project filter, and touching and holding the app's icon offers New session, Ask
Nook, Answer a chat and the two sessions that need you most (`AppShortcut`).

**Live conversation.** With a current Mac, an open session no longer asks every few seconds: the phone says which
session is on screen (`CompanionOp.watch`), the Mac answers with its recent conversation and from then on sends only
what changed after the last entry both have alike, over the live connection (`TimelineDelta`, `timelineAfter`). A phone
that misses the entry an update builds on asks for the whole conversation once; after a reconnect the open session is
watched again. An older Mac keeps the asking.

**Review.** *Changes* in a session's header lists every file it changed in its folder, the most changed first, with its
lines added and removed and its patch (`CompanionOp.diff`, cut to fit one answer). Tap a line, and another for a range,
then *Comment*: the comment goes into the session's message as a `<review_comment>` with the lines quoted, the block the
Mac's review sends.

**Pictures and model.** The composer of a session and of a new session take up to two pictures (JPEGs made small
enough on the phone, `CompanionImage`); the Mac saves them where its composer keeps pictures and gives the agent their
paths below the words. A new session can pick its model from the Mac's composer menu for that agent; anything else
falls back to your default.

**Nothing lost.** A message the Mac refuses stays in the session with why (*Not sent*), to edit and send again with its
pictures, or to discard.

A notification that an agent's turn finished, failed or hit a limit has a **Reply** field: what you type goes to that
session as a message (through the outbox), without opening the app.

## Pairing

1. **On your Mac:** Go to **Settings › iPhone**, enable **iPhone Companion**, and click **Pair an iPhone**. Nook displays a one-time QR code (and a `nook://pair?…` link) valid for 5 minutes.
2. **On your iPhone:** Open **Nook Companion** and scan the QR code (or paste the pairing link). The app registers the `nook://` scheme, so scanning the code with the Camera app opens it too.
3. The first authenticated request proves the phone holds the shared key; your Mac stores the paired device key in the macOS Keychain. Unpairing deletes the key on either side. When the Mac removes a phone that is connected live, it tells it first (see *When the Mac is out of reach*), so the phone says *Pair again* instead of looking for the Mac.

## Several Macs

One phone can pair with up to eight Macs (`CompanionPairings`, `packages/protocol/Sources/CompanionPairings.swift`, tested in `CompanionPairingsTests`). *Pair another Mac* is in the Agents menu (`…`), next to the list of paired Macs.

- **One active Mac:** the live connection, the tabs and the Live Activities follow the active Mac; picking another Mac in the menu moves the connection there. *Unpair from this Mac* removes only the active one.
- **The others in the Agents list:** every other Mac is asked for its sessions when the phone connects and every 30 seconds (one short `list` over its own routes), and its sessions show under *On <Mac>*, what waits on you first. A tap makes that Mac active and opens the session.
- **Kept per Mac:** each Mac has its own key, routes, features and outbox (`companion-outbox-<id>.json`), keyed by the id of its pairing key, so a message written to one Mac never goes to another. The Mac a phone was paired with before this keeps its old storage names; the single stored pairing is turned into the list on the first launch (`PairingStore`).
- Push notifications and Live Activities come from the Mac they belong to, and a button on a notification goes back to that Mac (the push names it, see *When the Mac is out of reach*), also when another Mac is active. A notification from a Mac that does not name itself goes to the active Mac.

## What the App Does

- **Today tab:** Nook's home, as the empty notch on the Mac: a greeting, what needs you (approve right there), the *For you* rows, your agenda, what plays on the Mac (play/pause, next, previous), your plan limits at a glance, and conversation starters that open a chat.
- **Usage tab:** Settings › Usage & costs on the phone: the 5-hour and weekly limits of every connected account with an even-pace mark and reset time, then sessions, tokens and reported costs of the sessions Nook started (today, week, month), tokens per day per agent, and usage per model.
- **Agents tab:** every session on the Mac, the ones waiting on you first. A session opens as a conversation: your messages, the agent's replies, the tools it ran and the files it changed, what waits on you (approve, deny, answer), and a field to send the next message. **Stop** ends a running session.
- **New session (`+`):** type a task, pick a connected agent and one of the folders you recently worked in on the Mac, and optionally *plan first* or work *on its own branch (worktree)*. Account, model, and effort come from the Mac's remembered choices for that agent.
- **Prompt links:** a `nook://prompt?text=…&project=…&agent=…` link (the same links the Mac opens) opens *New session* with the task filled in and the named folder and agent picked when the Mac offers them. It never starts by itself: you read the task and tap Start. Links are parsed by the shared `PromptLink` (`packages/protocol`), which strips hidden characters and refuses overlong text.
- **Quiet for what you are looking at:** a push about the session open on screen arrives without a banner or sound; the session's screen already shows what changed.
- **Chats tab:** the Mac's Chats tab: WhatsApp (through the phone linked to Nook) and every other chat app Nook collects on the Mac (Telegram, Messages, Slack…) in one list, newest first, with a search, *All / Unread*, and a badge for what is unread. A chat opens as bubbles (quotes, reactions, ticks, files by name). A WhatsApp chat can be answered from the phone, also as a reply to one of its messages (long-press it): your own words and your own tap, sent and logged as in the Chats tab on the Mac. Any other chat is read-only on the phone and answered in its own app; *@nook* drafting stays on the Mac. Opening a chat reads it in Nook the way opening it on the Mac does (Settings › Chat apps); *Mark as read* in a chat's menu passes that on to the chat's app where Nook can tell it (WhatsApp, Telegram, an app Nook's chat helper links), and *Mark as unread* is Nook's alone.
- **Nook tab:** Nook's own conversations (the same ones as in the notch). Ask a question in a new chat or continue one; the answer streams in. It runs through the same brain pipeline as on the Mac; plans, mail drafts, and charts in an answer are shown and approved on the Mac. A question from the phone does not open the notch.

Which of these the phone offers depends on the Mac: the `hello`/`list` answer lists the `features` it understands (`start`, `timeline`, `chat`, `home`, `usage`, `music`, `inbox`, `liveActivity`, `manage`, `stream`, `routes`, `retry`, `relay`, `requestUpdate`, `steer`, `liveTimeline`, `diff`, `images`, `clock`, `revoke`, `foreground`, `resume`). A Mac (or the Tauri app) without them keeps working with the approve/answer/send/stop features only.

## Versions

Most differences between an older Mac and a newer phone (or the other way round) are covered by `features`: the phone only offers what the Mac lists. For changes `features` cannot cover, both sides also say which **protocol version** and **app version** they run (`protocolVersion` and `appVersion` on `hello`, `list` and `subscribe`, both ways; the Mac adds `oldestPhone`, the oldest phone protocol it still supports). A side that sends none is version 1, so older Macs and phones keep working. `CompanionCompatibility` (`packages/protocol/Sources/CompanionCompatibility.swift`, tested in `CompanionCompatibilityTests`) turns that into **ok**, **Mac too old** or **phone too old**:

- The phone shows *Update Nook on your Mac* or *Update the app* above the Agents list.
- Settings › iPhone on the Mac shows the app version of each paired phone, and says when a phone's app is too old for this Nook.
- With a Mac that lists `requestUpdate`, *Show the update on your Mac* in the Agents menu opens Nook's update panel on the Mac (`AppUpdater.showPanel`) when an update is ready. It never installs anything: installing stays a click on the Mac. It is logged as `companion_update_request`.

## What a Phone May Do

Each paired phone has its own **scopes** (`CompanionScope`, `packages/protocol/Sources/CompanionScopes.swift`, tested in `CompanionScopesTests`): **read** (sessions, conversations, Today, usage), **approve** (allow, deny, answer questions), **operate** (start sessions, send messages, stop and manage them), **chats** (the Chats tab), **music** and **nookChat** (chatting with Nook).

- They are chosen next to the pairing code on the Mac (everything by default) and changed later per phone in Settings › iPhone › *What this iPhone may do*. A phone paired before scopes existed may do everything, as before; a scope name a Mac does not know (from a newer Nook) is ignored.
- One table (`CompanionScopes.table`) says which scope each request needs; connection requests (`hello`, `list`, `subscribe`, `ping`) and the phone's own token registrations always pass. The test fails when a new op has no entry, and an op missing from the table is refused.
- The Mac refuses a request outside the phone's scopes (`notAllowedFromPhone`), leaves out of every answer what the phone may not see, lists only the features it may use, and sends the phone its scopes with every `hello`, `list` and `subscribe` answer. The phone hides what it may not use (approve buttons, the message field, the Chats and Nook tabs). A change on the Mac ends the phone's live connection, so it reconnects and learns at once.

## Security Architecture

- **Out-of-band key exchange:** The 32-byte random key is transferred exclusively via the QR code and never sent over the network.
- **End-to-end authenticated encryption:** Every message is sealed with **ChaCha20-Poly1305** (keys derived via HKDF from the pairing key, with device ID and direction bound in the associated data). Anyone on the same Wi-Fi network cannot read session titles or commands, nor modify or forge requests.
- **Replay & rate protection (`RequestGuard`):** Every request carries a timestamp (max 60 s skew; a phone whose clock is further off corrects for it, see *When the Mac is out of reach*) and a unique nonce. The Mac rejects stale or replayed requests and enforces a limit of 120 requests/minute per device, up to 8 concurrent connections, 256 KB max message size, and a 30 s connection timeout.
- **Least-privilege policy (`CompanionPolicy`):** Denying a tool call is always permitted from the phone; **allowing a tool call from the phone is restricted to low-risk operations** (reading/editing files or shell commands classified as safe by `CommandRisk`). High-risk or unknown commands, web actions, and MCP tools must be approved on the Mac itself.
- **Starting sessions is narrowed:** the phone can only start an agent with a connected account in a folder from the Mac's recent projects (never an arbitrary path), and a session started from the phone never uses *allow everything* (`bypass`): it falls back to *accept edits*, so risky actions still wait for approval. A folder another session works in is refused, as in the composer.
- **Full audit trail:** Every action taken from the phone is recorded in the local SQLite audit log (`companion_allow`, `companion_deny`, `companion_answer`, `companion_send`, `companion_steer`, `companion_stop`, `companion_start`, `companion_ask`, `companion_chat_stop`, `companion_music`, `companion_chat_send`, `companion_chat_read`, `companion_chat_unread`, `companion_update_request`, `companion_paired`); a message sent to a chat is also logged as `whatsapp_send`, as from the Mac.

## Staying Connected

The phone keeps one live connection to the Mac while the app is in front, modeled on how remote clients of agent harnesses keep their connection (routes, a supervisor, a heartbeat and an outbox). Every message on it stays sealed as described above.

- **Routes:** a paired Mac has an ordered list of ways to reach it (`CompanionRoute`): its `.local` name, its LAN addresses, and its Tailscale address. The pairing code carries the addresses the Mac has now (`&a=…`), so a phone that cannot resolve the `.local` name still pairs. Routes are ordered local network first, then the tailnet or another VPN, then the internet (`CompanionRoutes.rank`).
- **The Mac shares where it can be reached:** every `hello`, `list` and `subscribe` answer carries `endpoints` (`CompanionEndpoints`: the Bonjour name and the IPv4 addresses of its interfaces; an address in 100.64/10 on a `utun` interface is marked as Tailscale). The phone keeps them as *learned* routes and drops the ones the Mac stops reporting (`CompanionRoutes.merge`), so the Mac's new Wi-Fi address, or its Tailscale address away from home, works without pairing again. Routes from the pairing code's host are never dropped. Settings › iPhone shows the addresses on the Mac.
- **Picking a route:** all routes are asked for the list at once (`RouteProbe.pick`). The earliest route that answers wins once every earlier one failed; the earlier routes get a head start of half a second, after which any route that answered is used, so a LAN the phone left does not hold up the Tailscale route. An answer only counts when it opens with the pairing key, so an address that now belongs to another machine is skipped. When nothing answers, Bonjour looks for the Mac on another port.
- **Live connection:** with a Mac that lists `stream`, the phone subscribes (`subscribe`). The Mac answers like `list`, then sends the sessions again whenever they change (at most once a second, with a growing `seq` the phone checks, so an old message played back cannot turn the list back). Other requests travel over the same connection. The phone pings every 5 seconds and drops a connection that sent nothing back for 15 seconds; the Mac closes one that was quiet for 45 seconds, and keeps one live connection per phone. A Mac without `stream` is asked for the list every 5 seconds, as before.
- **Reconnecting:** one supervisor owns retries: exponential backoff with jitter from 1 second up to a minute, reset after a connection stayed up for 30 seconds (`RetryBackoff`). Coming back to the app after 10 seconds or more replaces the connection at once (iOS can kill a suspended socket without a word); after a shorter glance a 3-second probe is enough (`CompanionWakeup`). A change of network (Wi-Fi to cellular, another Wi-Fi network) probes the connection and ends any wait.
- **Moving back to a better route:** while connected over a later route (Tailscale), the phone checks the earlier ones every minute and on a network change, and moves over as soon as one answers. A route that answered but then failed to connect is left alone for 5 minutes (`RouteCooldowns`), so a flaky network cannot bounce the connection.
- **Outbox and retries:** with a Mac that lists `retry`, what you write goes through an outbox on the phone (`CompanionOutbox`, a protected file): a message to a session, a new session, a question to Nook and a message to a chat. Each shows where it belongs as waiting (in its session; *New session · waiting for your Mac* at the top of the Agents list; *New chat · waiting for your Mac* in the Nook tab, or dimmed in its chat; dimmed in a chat of the Chats tab; a long press lets it go), goes as soon as the Mac answers, and keeps its request id. A new chat whose first question waited becomes that chat once the Mac took it. The Mac remembers its answer to every request that changes something (`CommandReceipts`: messages, approvals, answers, stops, starts, questions to Nook, chat messages and marks, the player, session management and token registrations), so a repeat of the same id (a lost answer, a message sent again from the outbox) gets that answer and is never carried out twice; a repeat that arrives while the first is still running waits for its answer. The repeat must still be fresh and within the rate. The Mac keeps at most 256 answers per phone, the least recently asked for dropped first, each for at most 25 hours (longer than a message may wait in the outbox). A message to a session that waited more than a day is dropped; a new session, a question to Nook or a chat message after an hour, since started or sent much later it would surprise more than help (`CompanionOutbox.maxAge(for:)`). A refusal that will not pass (a folder another session works in, no brain on the Mac) takes a new session, a question or a chat message out of the outbox with why, so it never holds up what waits behind it; only a busy session keeps a message waiting (`CompanionOutbox.waitsAfter`). Approvals, answers and stops never wait in the outbox: they mean something only now (a button on a notification is the one exception, see below).

## When the Mac is out of reach

What keeps the phone useful while it cannot reach the Mac, or reaches it late (`packages/protocol/Sources/CompanionResilience.swift`, tested in `CompanionResilienceTests`; on the phone `CompanionStores.swift` and `CompanionClient.swift`).

- **Buttons on notifications reach their Mac from anywhere.** A push names the pairing it went out for (`mac` under `nook`, `APNsPayload.make`, and in the sealed relay content, `RelayPushContent.mac`): the pairing key's public identifier, which the Mac knows the phone by and the phone knows the Mac by. Allow, Deny and Reply go to that Mac, also when another Mac is active and from a cold start (the pairings are read again once the phone is unlocked; the buttons ask to unlock, since the pairings only open then). With a live connection to that Mac the request goes over it; otherwise the app keeps running in the background for it (`beginBackgroundTask`), looks for the best route over all of that Mac's routes, Tailscale and the relay included (`RouteProbe.pick`, with a `list`), and sends the request once over the route that answered. When nothing answers it posts a notification of its own, *Couldn't reach <Mac>. Tap to try again.* A Deny or a Reply is kept for 15 minutes (`NotificationRetries`, `companion-notification-retries.json`) and tried again on that tap, when the app comes to the front and when the phone connects to that Mac; a Reply also waits in that Mac's outbox. The request keeps its id, so trying again is safe (`CommandReceipts`). An Allow is never kept: allowing later than you meant is another decision; its notification says to answer again.
- **No stale notifications.** On every list a Mac answers, the phone removes the delivered notifications of that Mac about an approval or a question that no longer waits (answered on the Mac or elsewhere), and sets the badge to what still waits on the active Mac (`DeliveredNotifications`). A notification from a Mac that does not name itself counts as the active Mac's only when the phone is paired with one Mac.
- **What the phone saw last.** The phone keeps, per Mac, the last list with the time the Mac answered it, what a new session can start with, and the conversations of the last five sessions that were open (the newest 200 entries each) in `companion-cache-<id>.json` (readable after the first unlock; `CompanionCache`, `CacheStore`). At launch they show at once; while the Mac cannot be reached the Agents list says *Last updated HH:mm · not connected*, so it never looks live, and a live answer always replaces it (an older list never replaces a newer one). With a Mac that lists `resume`, opening a session sends the last entry the phone has with `watch` (`item`), and the Mac answers with that entry and what came after it (`TimelineDelta.resume`), so only the change travels.
- **A clock that is off.** The Mac refuses a request more than 60 seconds off its clock (`stale`). A Mac that lists `clock` says its own time with that refusal (`macTime`); the phone keeps the difference per Mac, at most a day either way (`CompanionClock`, `ClockOffsets`), adds it to the time of every later request to that Mac, and tries again at once. A `stale` refusal that does not correct itself waits the longest backoff (up to a minute) instead of asking again every second.
- **Removed on the Mac.** With `revoke`, a Mac that removes a phone (Settings › Connections › iPhone) first sends it, over its live connection, an update with `revoked` (sealed with its key, which the Mac forgets a moment later). From that moment the Mac refuses anything else from the phone, so a lost phone cannot slip in a last request while the message goes out. The phone stops looking for that Mac, ends its Live Activities, forgets its push key, its outbox and what it kept of it, and says *<Mac> removed this iPhone. Pair again to use it from here.* (on the pairing screen, or above the list when another Mac is still paired). A phone that is not connected when it is removed finds out the old way: the Mac no longer answers it.
- **No push for what is on screen.** With `foreground`, the phone says with `subscribe` and its probes whether the app is in front, and that it went to the background. The Mac leaves out the push for a phone that is connected live, in front, and heard from in the last 10 seconds (`ForegroundPolicy`): the live connection already shows it. A phone that goes quiet gets its pushes again.

## Away from Home

From a café, a train or mobile data the phone reaches the Mac in one of two ways. Both keep every message sealed end to end with the pairing key, and both are routes like any other: at home the phone moves back to the local network by itself.

- **Tailscale:** install Tailscale on the Mac and on the iPhone, signed in to the same account. The Mac reports its Tailscale address (an address in 100.64/10 on a `utun` interface) and the phone keeps it as a route. Settings › iPhone on the Mac says whether Tailscale runs and at which address; without it, it says what to install. Nothing else to set up.
- **A relay, with one switch:** Settings › iPhone › *Away from home* › **Reach this Mac away from home**. No Tailscale and no port on the router: the Mac connects out to the relay, and the phone meets it there.
  - **Nook's relay** (the default, in builds that carry one): nothing else to do. Nook's relay is `apps/relay`, deployed by the `relay-deploy.yml` workflow; its address reaches the app through the build setting `NOOK_RELAY_URL` (Info.plist `NookRelayURL`, set in `release.yml` from the repository variable of the same name). A build without it offers only your own relay.
  - **Your own relay** on a free Cloudflare account, set up from Settings without a command line: **Open Cloudflare** opens Cloudflare's token page with the permissions filled in (deploying Workers, reading the account); paste the token and click **Set up**. Nook (`CloudflareRelayDeployer`) uploads the relay's code that ships inside the app (`Resources/worker`, from `apps/relay/worker`), turns on its `workers.dev` address (creating the account's subdomain when it has none), waits until it answers, and switches to it. The token stays in the Keychain, so a relay Nook set up gets the relay code of each new Nook version by itself. A relay deployed some other way (`npx wrangler@4 deploy`, see [`apps/relay/README.md`](../apps/relay/README.md)) is entered under *I already have a relay*.
  - **Rooms:** the Mac keeps one outgoing WebSocket per paired phone (and one for an open pairing window, so a phone can even pair away from home), in a room named after the pairing key (`CompanionRelay.room`: the first 16 bytes of HMAC-SHA256 of the key, so the room tells nothing about the key). A phone connects to the same room; the relay numbers each phone connection and passes bytes (`RelayMux`: `[kind][connection][payload]`).
  - **What the relay sees:** which room talks, when and how much. It cannot read titles, messages or commands, and cannot forge or change a request (the seal, the freshness check and the replay guard work as on the local network). A phone that comes while the Mac is not connected is told so at once (close code 4404), so it tries the next route.
  - **How phones learn it:** the pairing code carries the relay's address (`&r=…`), and every `hello`, `list` and `subscribe` answer says which relay the Mac uses (`relay`, empty when none), so a phone paired before picks it up the next time it connects at home. The relay route is always the last resort, after every direct route.
  - **Keep-alive:** the Mac sends `ping` every 30 seconds, answered by the relay without waking the room (an idle connection costs nothing), and replaces a socket that heard nothing for 75 seconds; it reconnects with the same backoff as the phone.
- The phone shows how it is connected (local network, Tailscale, relay) in the Agents menu, and, when it cannot reach the Mac, what to set up for away from home.

## When It Does Not Connect

- **On the phone:** *Why can't I connect?* (under the banner while the Mac cannot be reached, and *Check the connection* in the Agents menu) checks every route once more, in detail (`RouteDiagnostics` in `apps/ios/NookCompanion/CompanionConnection.swift`): nothing reachable, something that answers without this pairing's key, a connection the Mac closes without a word (it no longer knows this phone), the relay's close code (4404: the Mac is not connected to the relay; 4429: the room is full), a refusal (a clock too far off), or an answer and how long it took. `CompanionDiagnosis` (`packages/protocol/Sources/CompanionDiagnosis.swift`, tested in `CompanionDiagnosisTests`) turns that, with the last refusal of the live connection and the version check, into one headline, each hop on the way (this iPhone, the local network, Tailscale, the relay, Nook on the Mac) as works / failed / not checked, and the steps to fix it.
- **On the Mac:** Settings › iPhone › *Away from home* › **Test relay** sends a `ping` into a paired phone's room on the relay, sealed with that phone's key, and waits for this Mac's own answer to come back the same way: the whole path the phone takes from away. It shows the round-trip time, or what failed (the relay cannot be reached, the Mac is not in the room, no answer in time), with the same model.

## Diagnostics

The Mac and the phone each keep a local log of how the companion connects (`CompanionDiagnosticsLog`, `packages/protocol/Sources/CompanionDiagnosticsLog.swift`, tested in `CompanionDiagnosticsLogTests`): one JSON object per line, at most 256 KB with one older file kept (`companion-diagnostics.ndjson` in Nook's support folder on the Mac, in the app's Application Support on the phone).

- **What it records:** on the phone the route chosen (its kind, never its address), unreachable attempts, refusals, closed and failed connections with how long they lasted, wakeups, network changes, moves to a better route, Mac switches and each "Why can't I connect?" result; on the Mac refusals (with the clock difference), pairings, live connections that opened or closed, the relay rooms connecting and closing (with the close code), relay reconnects and *Test relay* results.
- **Copy diagnostics** (Settings › iPhone on the Mac; "Why can't I connect?" on the phone) puts a copy on the clipboard with a short header (versions, what is set up, each phone's app version and scopes). Every line is redacted first (`CompanionRedaction`): IPv4 and IPv6 addresses become the kind of network (`<lan>`, `<vpn>`…), `.local` and `.ts.net` names and relay addresses become placeholders, and ids, rooms, keys and tokens are removed.
- Nothing is sent anywhere: the user decides where to paste it.

## Keeping the Mac Awake

A Mac that sleeps drops its connection to the relay and to Tailscale, so the phone cannot reach it any more than one that is off. Settings › iPhone › *Away from home* › **Keep this Mac awake** (`KeepAwake`, rules in `KeepAwakePolicy`, tested in `KeepAwakePolicyTests`):

- **While agents work** (the default): while a session works or waits on you (an approval, a question), for five minutes after the last one, and while an iPhone is connected live, so a follow-up from the phone still finds the Mac.
- **Always:** whenever the companion is on.
- **Off.**

On the power adapter Nook holds off all sleep (`PreventSystemSleep`), which keeps a MacBook awake with its lid closed too; on battery only idle sleep (`PreventUserIdleSystemSleep`), only for work or a connected phone (never for *Always* alone), and never below 20% charge. The screen still turns off. The assertions are named "Nook: keeps this Mac reachable for your iPhone" (`pmset -g assertions`), and Settings shows why the Mac is kept awake right now. When the Mac wakes or changes networks it connects to the relay again at once instead of waiting for the keep-alive to notice. A Mac that is shut down cannot be reached at all: messages to a session wait in the phone's outbox (up to a day) until it is back.

## Scope & Intentional Boundaries

- Works on the same local network, over Tailscale or another VPN, and through a relay: Nook's own, or one on your own Cloudflare account (see *Away from Home*). Either way the relay only passes sealed bytes; without Tailscale or a relay, the Mac is reachable only at home. Using a relay is opt-in.
- Interactive actions (approve, answer, send, stop) require a connection to the Mac; push notifications arrive anywhere with internet access, and their buttons look for the Mac over every route, the relay included (see *When the Mac is out of reach*). What you write waits in the outbox instead.
- Nothing runs in the background on the phone: the live connection exists while the app is in front, and pushes cover the rest.
- The Mac listener only runs when **iPhone Companion** is enabled in Settings.

## Code Locations

- **Shared protocol:** `packages/protocol/Sources/CompanionModels.swift` (protocol, framing, policy rules; tested in `CompanionModelsTests`), `CompanionRoutes.swift` (routes, backoff, wakeups, outbox, receipts; tested in `CompanionRoutesTests`), `CompanionResilience.swift` (clock offset, stale notifications, notification retries, the phone's cache, resuming a conversation, the foreground rule; tested in `CompanionResilienceTests`), `PromptLink.swift` (`nook://prompt` links, tested in `PromptLinkTests`), `CompanionSeal.swift` (CryptoKit ChaCha20-Poly1305), `WebhookSecurity.swift` (SHA-256 / HMAC).
- **macOS app:** `apps/macos/Services/Companion/CompanionServer.swift` (`NWListener` + Bonjour `_nookcompanion._tcp`), `CompanionServer+Remote.swift` (starting sessions, timelines, Nook chats), `CompanionServer+Home.swift` (home, usage, player), `CompanionServer+Chats.swift` (the Chats tab, from the same `ChatsEntry.all` list as on the Mac), `CompanionStore.swift` (paired devices & pairing window), `apps/macos/App/Settings/CompanionSettings.swift`.
- **Live Activities:** `packages/protocol/Sources/CompanionLiveActivity.swift` (phases, attributes, content, `LiveActivityPlanner`, `LiveActivityPayload`; tested in `CompanionModelsTests`), `apps/macos/Services/Companion/CompanionNotifier.swift` and `APNsClient.swift` (the pushes), `apps/ios/NookActivity/` (the widget extension), `apps/ios/NookCompanion/LiveActivities.swift` (tokens, the switch, updates while the app is open).
- **Away from home:** `packages/protocol/Sources/CompanionRelay.swift` (rooms, relay addresses, `RelayMux`; tested in `CompanionRelayTests`), `apps/macos/Services/Companion/CompanionRelayClient.swift` (the Mac's rooms, Nook's or your own relay), `CloudflareRelaySetup.swift` and `CloudflareRelayDeployer.swift` (setting up your own relay from Settings; tested in `CloudflareRelaySetupTests`), `KeepAwake.swift` and `KeepAwakePolicy.swift` (keeping the Mac awake), `RouteLink` in `apps/ios/NookCompanion/CompanionConnection.swift` (the phone's WebSocket), and the relay itself in `apps/relay` (tested with `npm test`).
- **Staying connected:** `apps/macos/Services/Companion/CompanionEndpoints.swift` (the Mac's addresses), the live connections in `CompanionServer.swift`; on the phone `apps/ios/NookCompanion/CompanionConnection.swift` (`CompanionChannel`, `RouteProbe`) and the supervisor in `CompanionClient.swift`.
- **iOS app:** `apps/ios/NookCompanion/` (XcodeGen project in `apps/ios/project.yml`; see [`apps/ios/README.md`](../apps/ios/README.md)).

## Shared Fixtures

The wire format is pinned by golden fixtures in `packages/protocol/Fixtures` that every implementation reads in its own tests, so the Mac, the iPhone app, the Tauri app and the relay cannot drift apart: requests and responses as they travel, sealed frames with a fixed key and nonce, the 4-byte framing, relay rooms, mux frames and close codes, and pairing links (valid and refused).

| Fixture | Swift (`CompanionFixturesTests`, Mac and iPhone share the code) | Rust (`apps/tauri/core/src/companion/fixtures.rs`, `cargo test`) | Relay (`apps/relay/test/fixtures.test.js`, `npm test`) |
| --- | --- | --- | --- |
| `requests.json` | all | the `core` ones (approve/answer/send/stop/register) | — |
| `responses.json` | all | the `core` ones; unknown fields ignored | — |
| `sealed.json` | yes (CryptoKit: on a Mac, not in the Linux core tests) | yes | — |
| `framing.json` | yes | yes | — |
| `pairing.json` | yes, with alternates and relay | host, port, key, name | — |
| `relay.json` | rooms, mux, close codes | — | rooms, mux, close codes |

A change to the wire format starts with the fixture; each implementation's test then says what still needs to follow.

## Direct APNs Push Notifications

Nook sends push notifications directly from your Mac without any intermediary server: your Mac signs the APNs JWT using your own Apple Developer `.p8` key and sends it straight to Apple (`api.push.apple.com`).

**One-time setup (Apple Developer account):**
1. Enable **Push Notifications** for the `nl.imdigital.nook.companion` App ID (or your custom bundle ID) in *Certificates, Identifiers & Profiles › Identifiers*.
2. Create an APNs key (*Keys › + › Apple Push Notifications service*) and download the `.p8` file. Note your **Key ID** and **Team ID**.
3. In Nook on your Mac (**Settings › iPhone Companion › Push Notifications**), enter your Key ID and Team ID and import the `.p8` file (stored in the macOS Keychain). Click **Send Test Notification** to verify.
4. On your iPhone, allow notifications when prompted. The app sends its push token (encrypted) to your Mac.

**Privacy:** Because push payloads pass through Apple's APNs servers, Nook sends only the agent name and status by default (e.g., `"Claude Code · Waiting for your approval"`). Session titles are omitted unless you explicitly opt in, and commands, file paths, or answers are never included in push payloads. Besides the text, a push carries ids only: the session, the approval or question, and the pairing's public identifier (`mac`, the first 8 bytes of the pairing key's SHA-256, which tells nothing about the key) so its buttons reach the right Mac.

## Live Activities

While a session works on the Mac, Nook Companion shows it as a **Live Activity** on the Lock Screen and in the Dynamic Island: one per session, with its project, title, agent and model, and its phase: **working** (with a running timer), **waiting for you** (an approval or a question), **done** or **failed**. A tap opens the session in the app. It needs no cloud relay.

**How it runs**

- The phone hands the Mac its tokens with the `liveActivity` request (`LiveActivityRegistration`): the **push-to-start token** (iOS 17.2+) and the **update token** of every activity on the phone. It only does so with a Mac that lists the `liveActivity` feature, so an older Mac never sees the new request; an older phone simply never registers.
- On every change of a session (and every 15 seconds) the Mac's `LiveActivityPlanner` works out, per phone, what to send: **start** when a session begins to work, **update** when its phase changes, **end** when it is done or failed or gone from the list. The pushes go straight to Apple with the user's own APNs key (the same setup as notifications), with `apns-push-type: liveactivity` and the topic `nl.imdigital.nook.companion.push-type.liveactivity`.
- **A finished result stays up to 15 minutes**: the end push carries a dismissal date 15 minutes out, so it disappears on time even when the Mac is gone by then.
- **A stale date** 10 minutes out goes with every start and update, and a working session gets a quiet (priority 5) refresh every 4 minutes that moves it on. When the Mac sleeps, quits or loses the network, the activity reads **Out of date** instead of claiming the agent still works.
- **Rate limits:** a phase change goes out at once (priority 10) but not within 5 seconds of the previous push; a new title or model waits 30 seconds; at most 5 activities at once; a session whose activity just ended does not get a new one within a minute. Start and end pushes (and failed pushes) are logged as `companion_live` in the audit log; a token Apple refuses is dropped.
- While the app is open it keeps the activities current itself with the same rules, and starts them when the Mac cannot (no push set up, or iOS before 17.2). A session gets one activity: a twin from a push-to-start that crossed a local start is ended.

**Turning it off:** *Live Activities* in the menu (`…`) of the Agents tab on the phone. Off ends every activity and sends `off`: the Mac forgets the phone's tokens and sends nothing until it is turned on again. iOS's own switch (Settings › Nook Companion › Live Activities) works too. On the Mac, Live Activities need push notifications set up and on (Settings › iPhone Companion › Push Notifications).

**Privacy:** Live Activity pushes pass through Apple like notifications, and follow the same choice: the session title and folder are only sent when **Include session title** is on. Otherwise a push-started activity shows the agent and its phase; one the app started itself keeps the title it had. Commands, files and answers are never sent.

## Push through Nook's relay

For a Mac without an Apple developer account: **Settings › iPhone Companion › Push Notifications › Send through ›
Nook's relay**. It is the default when the build carries Nook's relay and you have not set up your own key; **My own
APNs key** keeps the direct path above.

How it works (end to end sealed):

1. For each paired phone, the Mac seals what the notification says (title, text, category, session and item ids, badge)
   with `CompanionSeal`, unchanged, using a **push key** derived from that phone's pairing key
   (`HMAC-SHA256(pairingKey, "nook-companion-push-v1")`, `RelayPush.pushKey`). The collapse id is a keyed hash too.
2. It posts the phone's device token, its room and the sealed blob to the relay's `POST /v1/push`
   (`apps/relay/worker/push.js`). The relay limits pushes per room and per device token, logs nothing, signs an APNs
   request with Nook's own APNs key (Worker secrets) and sends Apple a generic alert ("Nook needs you") with
   `mutable-content` and the blob under `nook-sealed`.
3. On the phone, the **Notification Service Extension** (`apps/ios/NookNotifications`) opens the blob with the push key
   and writes the real title, text, buttons, thread and badge. Without a key that opens it, the notification says
   "Nook needs you".

The app keeps the push keys (never the pairing keys) in one Keychain item in the app group's access group
(`group.nl.imdigital.nook.companion`), readable after the first unlock so a push that arrives while the phone is locked
can still be opened (`PushKeyStore`). They are written when you pair and on every launch, and removed with the
pairing. Because the text is sealed, it is safe for the relay; it still follows **Include session title**.

**Setup for whoever runs the relay** (Nook's own, or yours): put the APNs key of the team that signs the companion app
into the Worker as secrets (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, optionally `APNS_TOPIC`; see
[`apps/relay/README.md`](../apps/relay/README.md#push-through-the-relay)). Without them `POST /v1/push` answers 501 and
the test button reports it. The companion app and its extension need the App Group
`group.nl.imdigital.nook.companion` enabled on both app ids (`nl.imdigital.nook.companion` and
`nl.imdigital.nook.companion.notifications`) in *Certificates, Identifiers & Profiles*. Pushes only reach phones running
a companion app signed by that same team: a self-built companion with another bundle id needs its own key and the
direct path.

Live Activities still go straight to Apple with your own key. Code: `packages/protocol/Sources/RelayPush.swift` and
`RelayPushSeal.swift` (tested in `RelayPushTests`, with a vector made outside Swift), `apps/macos/Services/Companion/RelayPushClient.swift`,
`apps/relay/worker/push.js` (tested with `npm test`), `apps/ios/NookNotifications/NotificationService.swift` and
`apps/ios/NookCompanion/PushKeyStore.swift`.
