# Nook Companion (iPhone)

**Nook Companion** is a lightweight iPhone app that shows which coding-agent sessions on your Mac need your attention, letting you **approve or deny tool calls, answer questions, send follow-up messages, and stop sessions**. With a current Nook on the Mac it can also **start new agent sessions, follow a session's whole conversation, and chat with Nook itself**. It communicates directly with Nook on your Mac over your local Wi-Fi network (or Tailscale/VPN)—with no cloud relay server in between.

## Pairing

1. **On your Mac:** Go to **Settings › Devices**, enable **iPhone Companion**, and click **Pair an iPhone**. Nook displays a one-time QR code (and a `nook://pair?…` link) valid for 5 minutes.
2. **On your iPhone:** Open **Nook Companion** and scan the QR code (or paste the pairing link).
3. The first authenticated request proves the phone holds the shared key; your Mac stores the paired device key in the macOS Keychain. Unpairing deletes the key on either side.

## What the App Does

- **Sessions tab:** every session on the Mac, the ones waiting on you first. A session opens as a conversation: your messages, the agent's replies, the tools it ran and the files it changed, what waits on you (approve, deny, answer), and a field to send the next message. **Stop** ends a running session.
- **New session (`+`):** type a task, pick a connected agent and one of the folders you recently worked in on the Mac, and optionally *plan first* or work *on its own branch (worktree)*. Account, model, and effort come from the Mac's remembered choices for that agent.
- **Chat tab:** Nook's own conversations (the same ones as in the notch). Ask a question in a new chat or continue one; the answer streams in. It runs through the same brain pipeline as on the Mac; plans, mail drafts, and charts in an answer are shown and approved on the Mac. A question from the phone does not open the notch.

Which of these the phone offers depends on the Mac: the `hello`/`list` answer lists the `features` it understands (`start`, `timeline`, `chat`). A Mac (or the Tauri app) without them keeps working with the approve/answer/send/stop features only.

## Security Architecture

- **Out-of-band key exchange:** The 32-byte random key is transferred exclusively via the QR code and never sent over the network.
- **End-to-end authenticated encryption:** Every message is sealed with **ChaCha20-Poly1305** (keys derived via HKDF from the pairing key, with device ID and direction bound in the associated data). Anyone on the same Wi-Fi network cannot read session titles or commands, nor modify or forge requests.
- **Replay & rate protection (`RequestGuard`):** Every request carries a timestamp (max 60 s skew) and a unique nonce. The Mac rejects stale or replayed requests and enforces a limit of 120 requests/minute per device, up to 8 concurrent connections, 256 KB max message size, and a 30 s connection timeout.
- **Least-privilege policy (`CompanionPolicy`):** Denying a tool call is always permitted from the phone; **allowing a tool call from the phone is restricted to low-risk operations** (reading/editing files or shell commands classified as safe by `CommandRisk`). High-risk or unknown commands, web actions, and MCP tools must be approved on the Mac itself.
- **Starting sessions is narrowed:** the phone can only start an agent with a connected account in a folder from the Mac's recent projects (never an arbitrary path), and a session started from the phone never uses *allow everything* (`bypass`): it falls back to *accept edits*, so risky actions still wait for approval. A folder another session works in is refused, as in the composer.
- **Full audit trail:** Every action taken from the phone is recorded in the local SQLite audit log (`companion_allow`, `companion_deny`, `companion_answer`, `companion_send`, `companion_stop`, `companion_start`, `companion_ask`, `companion_chat_stop`, `companion_paired`).

## Scope & Intentional Boundaries

- Works on the same local network (or over a VPN such as Tailscale using your Mac's hostname/address).
- Interactive actions (approve, answer, send, stop) require a live connection to the Mac; push notifications arrive anywhere with internet access, and their inline actions execute as soon as the phone can reach the Mac.
- The Mac listener only runs when **iPhone Companion** is enabled in Settings.

## Code Locations

- **Shared protocol:** `packages/protocol/Sources/CompanionModels.swift` (protocol, framing, policy rules; tested in `CompanionModelsTests`), `CompanionSeal.swift` (CryptoKit ChaCha20-Poly1305), `WebhookSecurity.swift` (SHA-256 / HMAC).
- **macOS app:** `apps/macos/Services/Companion/CompanionServer.swift` (`NWListener` + Bonjour `_nookcompanion._tcp`), `CompanionServer+Remote.swift` (starting sessions, timelines, Nook chats), `CompanionStore.swift` (paired devices & pairing window), `apps/macos/App/Settings/CompanionSettings.swift`.
- **iOS app:** `apps/ios/NookCompanion/` (XcodeGen project in `apps/ios/project.yml`; see [`apps/ios/README.md`](../apps/ios/README.md)).

## Direct APNs Push Notifications

Nook sends push notifications directly from your Mac without any intermediary server: your Mac signs the APNs JWT using your own Apple Developer `.p8` key and sends it straight to Apple (`api.push.apple.com`).

**One-time setup (Apple Developer account):**
1. Enable **Push Notifications** for the `nl.imdigital.nook.companion` App ID (or your custom bundle ID) in *Certificates, Identifiers & Profiles › Identifiers*.
2. Create an APNs key (*Keys › + › Apple Push Notifications service*) and download the `.p8` file. Note your **Key ID** and **Team ID**.
3. In Nook on your Mac (**Settings › iPhone Companion › Push Notifications**), enter your Key ID and Team ID and import the `.p8` file (stored in the macOS Keychain). Click **Send Test Notification** to verify.
4. On your iPhone, allow notifications when prompted. The app sends its push token (encrypted) to your Mac.

**Privacy:** Because push payloads pass through Apple's APNs servers, Nook sends only the agent name and status by default (e.g., `"Claude Code · Waiting for your approval"`). Session titles are omitted unless you explicitly opt in, and commands, file paths, or answers are never included in push payloads.
