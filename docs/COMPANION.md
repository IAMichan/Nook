# Nook Companion (iPhone)

**Nook Companion** is a lightweight iPhone app that shows which coding-agent sessions on your Mac need your attention, letting you **approve or deny tool calls, answer questions, send follow-up messages, and stop sessions**. With a current Nook on the Mac it can also **start new agent sessions, follow a session's whole conversation, and chat with Nook itself**. It communicates directly with Nook on your Mac over your local Wi-Fi network (or Tailscale/VPN)—with no cloud relay server in between.

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

Which of these the phone offers depends on the Mac: the `hello`/`list` answer lists the `features` it understands (`start`, `timeline`, `chat`, `home`, `usage`, `music`, `inbox`, `liveActivity`). A Mac (or the Tauri app) without them keeps working with the approve/answer/send/stop features only.

## Security Architecture

- **Out-of-band key exchange:** The 32-byte random key is transferred exclusively via the QR code and never sent over the network.
- **End-to-end authenticated encryption:** Every message is sealed with **ChaCha20-Poly1305** (keys derived via HKDF from the pairing key, with device ID and direction bound in the associated data). Anyone on the same Wi-Fi network cannot read session titles or commands, nor modify or forge requests.
- **Replay & rate protection (`RequestGuard`):** Every request carries a timestamp (max 60 s skew) and a unique nonce. The Mac rejects stale or replayed requests and enforces a limit of 120 requests/minute per device, up to 8 concurrent connections, 256 KB max message size, and a 30 s connection timeout.
- **Least-privilege policy (`CompanionPolicy`):** Denying a tool call is always permitted from the phone; **allowing a tool call from the phone is restricted to low-risk operations** (reading/editing files or shell commands classified as safe by `CommandRisk`). High-risk or unknown commands, web actions, and MCP tools must be approved on the Mac itself.
- **Starting sessions is narrowed:** the phone can only start an agent with a connected account in a folder from the Mac's recent projects (never an arbitrary path), and a session started from the phone never uses *allow everything* (`bypass`): it falls back to *accept edits*, so risky actions still wait for approval. A folder another session works in is refused, as in the composer.
- **Full audit trail:** Every action taken from the phone is recorded in the local SQLite audit log (`companion_allow`, `companion_deny`, `companion_answer`, `companion_send`, `companion_stop`, `companion_start`, `companion_ask`, `companion_chat_stop`, `companion_music`, `companion_chat_send`, `companion_chat_read`, `companion_chat_unread`, `companion_paired`); a message sent to a chat is also logged as `whatsapp_send`, as from the Mac.

## Scope & Intentional Boundaries

- Works on the same local network (or over a VPN such as Tailscale using your Mac's hostname/address).
- Interactive actions (approve, answer, send, stop) require a live connection to the Mac; push notifications arrive anywhere with internet access, and their inline actions execute as soon as the phone can reach the Mac.
- The Mac listener only runs when **iPhone Companion** is enabled in Settings.

## Code Locations

- **Shared protocol:** `packages/protocol/Sources/CompanionModels.swift` (protocol, framing, policy rules; tested in `CompanionModelsTests`), `PromptLink.swift` (`nook://prompt` links, tested in `PromptLinkTests`), `CompanionSeal.swift` (CryptoKit ChaCha20-Poly1305), `WebhookSecurity.swift` (SHA-256 / HMAC).
- **macOS app:** `apps/macos/Services/Companion/CompanionServer.swift` (`NWListener` + Bonjour `_nookcompanion._tcp`), `CompanionServer+Remote.swift` (starting sessions, timelines, Nook chats), `CompanionServer+Home.swift` (home, usage, player), `CompanionServer+Chats.swift` (the Chats tab, from the same `ChatsEntry.all` list as on the Mac), `CompanionStore.swift` (paired devices & pairing window), `apps/macos/App/Settings/CompanionSettings.swift`.
- **Live Activities:** `packages/protocol/Sources/CompanionLiveActivity.swift` (phases, attributes, content, `LiveActivityPlanner`, `LiveActivityPayload`; tested in `CompanionModelsTests`), `apps/macos/Services/Companion/CompanionNotifier.swift` and `APNsClient.swift` (the pushes), `apps/ios/NookActivity/` (the widget extension), `apps/ios/NookCompanion/LiveActivities.swift` (tokens, the switch, updates while the app is open).
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
