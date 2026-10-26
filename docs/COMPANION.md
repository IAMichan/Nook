# Nook Companion (iPhone)

**Nook Companion** is a lightweight iPhone app that shows which coding-agent sessions on your Mac need your attention, letting you **approve or deny tool calls, answer questions, send follow-up messages, and stop sessions**. With a current Nook on the Mac it can also **start new agent sessions, follow a session's whole conversation, and chat with Nook itself**. It communicates directly with Nook on your Mac over your local Wi-Fi network (or Tailscale/VPN) and, only when you turn it on, through a relay that passes sealed bytes it cannot read (see *Away from Home*). It keeps a live connection while it is open (see *Staying Connected*).

The phone sees two kinds of sessions:

- **Sessions Nook runs (Workspace):** approve or deny, answer questions, send messages, and stop them.
- **Agents running in a terminal on your Mac** (through their hooks, e.g. Claude Code in Terminal or iTerm) and requests through Nook's workspace bridge: they appear in the list and send push notifications for approvals, questions, and finished or failed turns. Approvals can be denied, and low-risk ones allowed, from the phone or straight from the notification; questions and messages are answered in the terminal (`apps/macos/Services/Companion/CompanionAgents.swift`).

## Pairing

1. **On your Mac:** Go to **Settings › Devices**, enable **iPhone Companion**, and click **Pair an iPhone**. Nook displays a one-time QR code (and a `nook://pair?…` link) valid for 5 minutes.
2. **On your iPhone:** Open **Nook Companion** and scan the QR code (or paste the pairing link). The app registers the `nook://` scheme, so scanning the code with the Camera app opens it too.
3. The first authenticated request proves the phone holds the shared key; your Mac stores the paired device key in the macOS Keychain. Unpairing deletes the key on either side.

## What the App Does

- **Today tab:** Nook's home, as the empty notch on the Mac: a greeting, what needs you (approve right there), the *For you* rows, your agenda, what plays on the Mac (play/pause, next, previous), your plan limits at a glance, and conversation starters that open a chat.
- **Usage tab:** Settings › Usage on the phone: the 5-hour and weekly limits of every connected account with an even-pace mark and reset time, then sessions, tokens and reported costs of the sessions Nook started (today, week, month), tokens per day per agent, and usage per model.
- **Agents tab:** every session on the Mac, the ones waiting on you first. A session opens as a conversation: your messages, the agent's replies, the tools it ran and the files it changed, what waits on you (approve, deny, answer), and a field to send the next message. **Stop** ends a running session.
- **New session (`+`):** type a task, pick a connected agent and one of the folders you recently worked in on the Mac, and optionally *plan first* or work *on its own branch (worktree)*. Account, model, and effort come from the Mac's remembered choices for that agent.
- **Prompt links:** a `nook://prompt?text=…&project=…&agent=…` link (the same links the Mac opens) opens *New session* with the task filled in and the named folder and agent picked when the Mac offers them. It never starts by itself: you read the task and tap Start. Links are parsed by the shared `PromptLink` (`packages/protocol`), which strips hidden characters and refuses overlong text.
- **Quiet for what you are looking at:** a push about the session open on screen arrives without a banner or sound; the session's screen already shows what changed.
- **Chats tab:** the Mac's Chats tab: WhatsApp (through the phone linked to Nook) and every other chat app Nook collects on the Mac (Telegram, Messages, Slack…) in one list, newest first, with a search, *All / Unread*, and a badge for what is unread. A chat opens as bubbles (quotes, reactions, ticks, files by name). A WhatsApp chat can be answered from the phone, also as a reply to one of its messages (long-press it): your own words and your own tap, sent and logged as in the Chats tab on the Mac. Any other chat is read-only on the phone and answered in its own app; *@nook* drafting stays on the Mac. Opening a chat reads it in Nook the way opening it on the Mac does (Settings › Chats); *Mark as read* in a chat's menu passes that on to the chat's app where Nook can tell it (WhatsApp, Telegram, an app Nook's chat helper links), and *Mark as unread* is Nook's alone.
- **Nook tab:** Nook's own conversations (the same ones as in the notch). Ask a question in a new chat or continue one; the answer streams in. It runs through the same brain pipeline as on the Mac; plans, mail drafts, and charts in an answer are shown and approved on the Mac. A question from the phone does not open the notch.

Which of these the phone offers depends on the Mac: the `hello`/`list` answer lists the `features` it understands (`start`, `timeline`, `chat`, `home`, `usage`, `music`, `inbox`, `liveActivity`, `manage`, `stream`, `routes`, `retry`, `relay`, `requestUpdate`). A Mac (or the Tauri app) without them keeps working with the approve/answer/send/stop features only.

## Versions

Most differences between an older Mac and a newer phone (or the other way round) are covered by `features`: the phone only offers what the Mac lists. For changes `features` cannot cover, both sides also say which **protocol version** and **app version** they run (`protocolVersion` and `appVersion` on `hello`, `list` and `subscribe`, both ways; the Mac adds `oldestPhone`, the oldest phone protocol it still supports). A side that sends none is version 1, so older Macs and phones keep working. `CompanionCompatibility` (`packages/protocol/Sources/CompanionCompatibility.swift`, tested in `CompanionCompatibilityTests`) turns that into **ok**, **Mac too old** or **phone too old**:

- The phone shows *Update Nook on your Mac* or *Update the app* above the Agents list.
- Settings › Devices on the Mac shows the app version of each paired phone, and says when a phone's app is too old for this Nook.
- With a Mac that lists `requestUpdate`, *Show the update on your Mac* in the Agents menu opens Nook's update panel on the Mac (`AppUpdater.showPanel`) when an update is ready. It never installs anything: installing stays a click on the Mac. It is logged as `companion_update_request`.

## Security Architecture

- **Out-of-band key exchange:** The 32-byte random key is transferred exclusively via the QR code and never sent over the network.
- **End-to-end authenticated encryption:** Every message is sealed with **ChaCha20-Poly1305** (keys derived via HKDF from the pairing key, with device ID and direction bound in the associated data). Anyone on the same Wi-Fi network cannot read session titles or commands, nor modify or forge requests.
- **Replay & rate protection (`RequestGuard`):** Every request carries a timestamp (max 60 s skew) and a unique nonce. The Mac rejects stale or replayed requests and enforces a limit of 120 requests/minute per device, up to 8 concurrent connections, 256 KB max message size, and a 30 s connection timeout.
- **Least-privilege policy (`CompanionPolicy`):** Denying a tool call is always permitted from the phone; **allowing a tool call from the phone is restricted to low-risk operations** (reading/editing files or shell commands classified as safe by `CommandRisk`). High-risk or unknown commands, web actions, and MCP tools must be approved on the Mac itself.
- **Starting sessions is narrowed:** the phone can only start an agent with a connected account in a folder from the Mac's recent projects (never an arbitrary path), and a session started from the phone never uses *allow everything* (`bypass`): it falls back to *accept edits*, so risky actions still wait for approval. A folder another session works in is refused, as in the composer.
- **Full audit trail:** Every action taken from the phone is recorded in the local SQLite audit log (`companion_allow`, `companion_deny`, `companion_answer`, `companion_send`, `companion_stop`, `companion_start`, `companion_ask`, `companion_chat_stop`, `companion_music`, `companion_chat_send`, `companion_chat_read`, `companion_chat_unread`, `companion_update_request`, `companion_paired`); a message sent to a chat is also logged as `whatsapp_send`, as from the Mac.

## Staying Connected

The phone keeps one live connection to the Mac while the app is in front, modeled on how remote clients of agent harnesses keep their connection (routes, a supervisor, a heartbeat and an outbox). Every message on it stays sealed as described above.

- **Routes:** a paired Mac has an ordered list of ways to reach it (`CompanionRoute`): its `.local` name, its LAN addresses, and its Tailscale address. The pairing code carries the addresses the Mac has now (`&a=…`), so a phone that cannot resolve the `.local` name still pairs. Routes are ordered local network first, then the tailnet or another VPN, then the internet (`CompanionRoutes.rank`).
- **The Mac shares where it can be reached:** every `hello`, `list` and `subscribe` answer carries `endpoints` (`CompanionEndpoints`: the Bonjour name and the IPv4 addresses of its interfaces; an address in 100.64/10 on a `utun` interface is marked as Tailscale). The phone keeps them as *learned* routes and drops the ones the Mac stops reporting (`CompanionRoutes.merge`), so the Mac's new Wi-Fi address, or its Tailscale address away from home, works without pairing again. Routes from the pairing code's host are never dropped. Settings › Devices shows the addresses on the Mac.
- **Picking a route:** all routes are asked for the list at once (`RouteProbe.pick`). The earliest route that answers wins once every earlier one failed; the earlier routes get a head start of half a second, after which any route that answered is used, so a LAN the phone left does not hold up the Tailscale route. An answer only counts when it opens with the pairing key, so an address that now belongs to another machine is skipped. When nothing answers, Bonjour looks for the Mac on another port.
- **Live connection:** with a Mac that lists `stream`, the phone subscribes (`subscribe`). The Mac answers like `list`, then sends the sessions again whenever they change (at most once a second, with a growing `seq` the phone checks, so an old message played back cannot turn the list back). Other requests travel over the same connection. The phone pings every 5 seconds and drops a connection that sent nothing back for 15 seconds; the Mac closes one that was quiet for 45 seconds, and keeps one live connection per phone. A Mac without `stream` is asked for the list every 5 seconds, as before.
- **Reconnecting:** one supervisor owns retries: exponential backoff with jitter from 1 second up to a minute, reset after a connection stayed up for 30 seconds (`RetryBackoff`). Coming back to the app after 10 seconds or more replaces the connection at once (iOS can kill a suspended socket without a word); after a shorter glance a 3-second probe is enough (`CompanionWakeup`). A change of network (Wi-Fi to cellular, another Wi-Fi network) probes the connection and ends any wait.
- **Moving back to a better route:** while connected over a later route (Tailscale), the phone checks the earlier ones every minute and on a network change, and moves over as soon as one answers. A route that answered but then failed to connect is left alone for 5 minutes (`RouteCooldowns`), so a flaky network cannot bounce the connection.
- **Outbox and retries:** with a Mac that lists `retry`, a message to a session goes through an outbox on the phone (`CompanionOutbox`, a protected file). It shows in its session as waiting, goes as soon as the Mac answers, and keeps its request id. The Mac remembers its answer to every request that changes something (`CommandReceipts`: messages, approvals, answers, stops, starts, questions to Nook, chat messages and marks, the player, session management and token registrations), so a repeat of the same id (a lost answer, a message sent again from the outbox) gets that answer and is never carried out twice; a repeat that arrives while the first is still running waits for its answer. The repeat must still be fresh and within the rate. The Mac keeps at most 256 answers per phone, the least recently asked for dropped first, each for at most 25 hours (longer than a message may wait in the outbox). A message that waited more than a day is dropped. Approvals, answers and stops never wait: they mean something only now.

## Away from Home

From a café, a train or mobile data the phone reaches the Mac in one of two ways. Both keep every message sealed end to end with the pairing key, and both are routes like any other: at home the phone moves back to the local network by itself.

- **Tailscale:** install Tailscale on the Mac and on the iPhone, signed in to the same account. The Mac reports its Tailscale address (an address in 100.64/10 on a `utun` interface) and the phone keeps it as a route. Settings › Devices on the Mac says whether Tailscale runs and at which address; without it, it says what to install. Nothing else to set up.
- **A relay, with one switch:** Settings › Devices › *Away from home* › **Reach this Mac away from home**. No Tailscale and no port on the router: the Mac connects out to the relay, and the phone meets it there.
  - **Nook's relay** (the default, in builds that carry one): nothing else to do. Nook's relay is `apps/relay`, deployed by the `relay-deploy.yml` workflow; its address reaches the app through the build setting `NOOK_RELAY_URL` (Info.plist `NookRelayURL`, set in `release.yml` from the repository variable of the same name). A build without it offers only your own relay.
  - **Your own relay** on a free Cloudflare account, set up from Settings without a command line: **Open Cloudflare** opens Cloudflare's token page with the permissions filled in (deploying Workers, reading the account); paste the token and click **Set up**. Nook (`CloudflareRelayDeployer`) uploads the relay's code that ships inside the app (`Resources/worker`, from `apps/relay/worker`), turns on its `workers.dev` address (creating the account's subdomain when it has none), waits until it answers, and switches to it. The token stays in the Keychain, so a relay Nook set up gets the relay code of each new Nook version by itself. A relay deployed some other way (`npx wrangler@4 deploy`, see [`apps/relay/README.md`](../apps/relay/README.md)) is entered under *I already have a relay*.
  - **Rooms:** the Mac keeps one outgoing WebSocket per paired phone (and one for an open pairing window, so a phone can even pair away from home), in a room named after the pairing key (`CompanionRelay.room`: the first 16 bytes of HMAC-SHA256 of the key, so the room tells nothing about the key). A phone connects to the same room; the relay numbers each phone connection and passes bytes (`RelayMux`: `[kind][connection][payload]`).
  - **What the relay sees:** which room talks, when and how much. It cannot read titles, messages or commands, and cannot forge or change a request (the seal, the freshness check and the replay guard work as on the local network). A phone that comes while the Mac is not connected is told so at once (close code 4404), so it tries the next route.
  - **How phones learn it:** the pairing code carries the relay's address (`&r=…`), and every `hello`, `list` and `subscribe` answer says which relay the Mac uses (`relay`, empty when none), so a phone paired before picks it up the next time it connects at home. The relay route is always the last resort, after every direct route.
  - **Keep-alive:** the Mac sends `ping` every 30 seconds, answered by the relay without waking the room (an idle connection costs nothing), and replaces a socket that heard nothing for 75 seconds; it reconnects with the same backoff as the phone.
- The phone shows how it is connected (local network, Tailscale, relay) in the Agents menu, and, when it cannot reach the Mac, what to set up for away from home.

## Keeping the Mac Awake

A Mac that sleeps drops its connection to the relay and to Tailscale, so the phone cannot reach it any more than one that is off. Settings › Devices › *Away from home* › **Keep this Mac awake** (`KeepAwake`, rules in `KeepAwakePolicy`, tested in `KeepAwakePolicyTests`):

- **While agents work** (the default): while a session works or waits on you (an approval, a question), for five minutes after the last one, and while an iPhone is connected live, so a follow-up from the phone still finds the Mac.
- **Always:** whenever the companion is on.
- **Off.**

On the power adapter Nook holds off all sleep (`PreventSystemSleep`), which keeps a MacBook awake with its lid closed too; on battery only idle sleep (`PreventUserIdleSystemSleep`), only for work or a connected phone (never for *Always* alone), and never below 20% charge. The screen still turns off. The assertions are named "Nook: keeps this Mac reachable for your iPhone" (`pmset -g assertions`), and Settings shows why the Mac is kept awake right now. When the Mac wakes or changes networks it connects to the relay again at once instead of waiting for the keep-alive to notice. A Mac that is shut down cannot be reached at all: messages to a session wait in the phone's outbox (up to a day) until it is back.

## Scope & Intentional Boundaries

- Works on the same local network, over Tailscale or another VPN, and through a relay: Nook's own, or one on your own Cloudflare account (see *Away from Home*). Either way the relay only passes sealed bytes; without Tailscale or a relay, the Mac is reachable only at home. Using a relay is opt-in.
- Interactive actions (approve, answer, send, stop) require a connection to the Mac; push notifications arrive anywhere with internet access, and their inline actions execute as soon as the phone can reach the Mac. Messages to a session wait in the outbox instead.
- Nothing runs in the background on the phone: the live connection exists while the app is in front, and pushes cover the rest.
- The Mac listener only runs when **iPhone Companion** is enabled in Settings.

## Code Locations

- **Shared protocol:** `packages/protocol/Sources/CompanionModels.swift` (protocol, framing, policy rules; tested in `CompanionModelsTests`), `CompanionRoutes.swift` (routes, backoff, wakeups, outbox, receipts; tested in `CompanionRoutesTests`), `PromptLink.swift` (`nook://prompt` links, tested in `PromptLinkTests`), `CompanionSeal.swift` (CryptoKit ChaCha20-Poly1305), `WebhookSecurity.swift` (SHA-256 / HMAC).
- **macOS app:** `apps/macos/Services/Companion/CompanionServer.swift` (`NWListener` + Bonjour `_nookcompanion._tcp`), `CompanionServer+Remote.swift` (starting sessions, timelines, Nook chats), `CompanionServer+Home.swift` (home, usage, player), `CompanionServer+Chats.swift` (the Chats tab, from the same `ChatsEntry.all` list as on the Mac), `CompanionStore.swift` (paired devices & pairing window), `apps/macos/App/Settings/CompanionSettings.swift`.
- **Live Activities:** `packages/protocol/Sources/CompanionLiveActivity.swift` (phases, attributes, content, `LiveActivityPlanner`, `LiveActivityPayload`; tested in `CompanionModelsTests`), `apps/macos/Services/Companion/CompanionNotifier.swift` and `APNsClient.swift` (the pushes), `apps/ios/NookActivity/` (the widget extension), `apps/ios/NookCompanion/LiveActivities.swift` (tokens, the switch, updates while the app is open).
- **Away from home:** `packages/protocol/Sources/CompanionRelay.swift` (rooms, relay addresses, `RelayMux`; tested in `CompanionRelayTests`), `apps/macos/Services/Companion/CompanionRelayClient.swift` (the Mac's rooms, Nook's or your own relay), `CloudflareRelaySetup.swift` and `CloudflareRelayDeployer.swift` (setting up your own relay from Settings; tested in `CloudflareRelaySetupTests`), `KeepAwake.swift` and `KeepAwakePolicy.swift` (keeping the Mac awake), `RouteLink` in `apps/ios/NookCompanion/CompanionConnection.swift` (the phone's WebSocket), and the relay itself in `apps/relay` (tested with `npm test`).
- **Staying connected:** `apps/macos/Services/Companion/CompanionEndpoints.swift` (the Mac's addresses), the live connections in `CompanionServer.swift`; on the phone `apps/ios/NookCompanion/CompanionConnection.swift` (`CompanionChannel`, `RouteProbe`) and the supervisor in `CompanionClient.swift`.
- **iOS app:** `apps/ios/NookCompanion/` (XcodeGen project in `apps/ios/project.yml`; see [`apps/ios/README.md`](../apps/ios/README.md)).

## Direct APNs Push Notifications

Nook sends push notifications directly from your Mac without any intermediary server: your Mac signs the APNs JWT using your own Apple Developer `.p8` key and sends it straight to Apple (`api.push.apple.com`).

**One-time setup (Apple Developer account):**
1. Enable **Push Notifications** for the `nl.imdigital.nook.companion` App ID (or your custom bundle ID) in *Certificates, Identifiers & Profiles › Identifiers*.
2. Create an APNs key (*Keys › + › Apple Push Notifications service*) and download the `.p8` file. Note your **Key ID** and **Team ID**.
3. In Nook on your Mac (**Settings › iPhone Companion › Push Notifications**), enter your Key ID and Team ID and import the `.p8` file (stored in the macOS Keychain). Click **Send Test Notification** to verify.
4. On your iPhone, allow notifications when prompted. The app sends its push token (encrypted) to your Mac.

**Privacy:** Because push payloads pass through Apple's APNs servers, Nook sends only the agent name and status by default (e.g., `"Claude Code · Waiting for your approval"`). Session titles are omitted unless you explicitly opt in, and commands, file paths, or answers are never included in push payloads.

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
