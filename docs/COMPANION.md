# Nook Companion (iPhone)

**Nook Companion** is a lightweight iPhone app that shows which coding-agent sessions on your Mac need your attention, letting you **approve or deny tool calls, answer questions, send follow-up messages, and stop sessions**. It communicates directly with Nook on your Mac over your local Wi-Fi network (or Tailscale/VPN)—with no cloud relay server in between.

The phone sees two kinds of sessions:

- **Sessions Nook runs (Workspace):** approve or deny, answer questions, send messages, and stop them.
- **Agents running in a terminal on your Mac** (through their hooks, e.g. Claude Code in Terminal or iTerm) and requests through Nook's workspace bridge: they appear in the list and send push notifications for approvals, questions, and finished or failed turns. Approvals can be denied, and low-risk ones allowed, from the phone or straight from the notification; questions and messages are answered in the terminal (`apps/macos/Services/Companion/CompanionAgents.swift`).

## Pairing

1. **On your Mac:** Go to **Settings › Devices**, enable **iPhone Companion**, and click **Pair an iPhone**. Nook displays a one-time QR code (and a `nook://pair?…` link) valid for 5 minutes.
2. **On your iPhone:** Open **Nook Companion** and scan the QR code (or paste the pairing link).
3. The first authenticated request proves the phone holds the shared key; your Mac stores the paired device key in the macOS Keychain. Unpairing deletes the key on either side.

## Security Architecture

- **Out-of-band key exchange:** The 32-byte random key is transferred exclusively via the QR code and never sent over the network.
- **End-to-end authenticated encryption:** Every message is sealed with **ChaCha20-Poly1305** (keys derived via HKDF from the pairing key, with device ID and direction bound in the associated data). Anyone on the same Wi-Fi network cannot read session titles or commands, nor modify or forge requests.
- **Replay & rate protection (`RequestGuard`):** Every request carries a timestamp (max 60 s skew) and a unique nonce. The Mac rejects stale or replayed requests and enforces a limit of 120 requests/minute per device, up to 8 concurrent connections, 256 KB max message size, and a 30 s connection timeout.
- **Least-privilege policy (`CompanionPolicy`):** Denying a tool call is always permitted from the phone; **allowing a tool call from the phone is restricted to low-risk operations** (reading/editing files or shell commands classified as safe by `CommandRisk`). High-risk or unknown commands, web actions, and MCP tools must be approved on the Mac itself.
- **Full audit trail:** Every action taken from the phone is recorded in the local SQLite audit log (`companion_allow`, `companion_deny`, `companion_answer`, `companion_send`, `companion_stop`, `companion_paired`).

## Scope & Intentional Boundaries

- Works on the same local network (or over a VPN such as Tailscale using your Mac's hostname/address).
- Interactive actions (approve, answer, send, stop) require a live connection to the Mac; push notifications arrive anywhere with internet access, and their inline actions execute as soon as the phone can reach the Mac.
- The Mac listener only runs when **iPhone Companion** is enabled in Settings.

## Code Locations

- **Shared protocol:** `packages/protocol/Sources/CompanionModels.swift` (protocol, framing, policy rules; tested in `CompanionModelsTests`), `CompanionSeal.swift` (CryptoKit ChaCha20-Poly1305), `WebhookSecurity.swift` (SHA-256 / HMAC).
- **macOS app:** `apps/macos/Services/Companion/CompanionServer.swift` (`NWListener` + Bonjour `_nookcompanion._tcp`), `CompanionStore.swift` (paired devices & pairing window), `apps/macos/App/Settings/CompanionSettings.swift`.
- **iOS app:** `apps/ios/NookCompanion/` (XcodeGen project in `apps/ios/project.yml`; see [`apps/ios/README.md`](../apps/ios/README.md)).

## Direct APNs Push Notifications

Nook sends push notifications directly from your Mac without any intermediary server: your Mac signs the APNs JWT using your own Apple Developer `.p8` key and sends it straight to Apple (`api.push.apple.com`).

**One-time setup (Apple Developer account):**
1. Enable **Push Notifications** for the `nl.imdigital.nook.companion` App ID (or your custom bundle ID) in *Certificates, Identifiers & Profiles › Identifiers*.
2. Create an APNs key (*Keys › + › Apple Push Notifications service*) and download the `.p8` file. Note your **Key ID** and **Team ID**.
3. In Nook on your Mac (**Settings › iPhone Companion › Push Notifications**), enter your Key ID and Team ID and import the `.p8` file (stored in the macOS Keychain). Click **Send Test Notification** to verify.
4. On your iPhone, allow notifications when prompted. The app sends its push token (encrypted) to your Mac.

**Privacy:** Because push payloads pass through Apple's APNs servers, Nook sends only the agent name and status by default (e.g., `"Claude Code · Waiting for your approval"`). Session titles are omitted unless you explicitly opt in, and commands, file paths, or answers are never included in push payloads.
