# ADR: Linking Messenger, Signal, Discord, LinkedIn and X without Beeper

- **Status:** Accepted, implemented (see "Implementation" below)
- **Date:** 2026-10-23
- **Scope:** `apps/macos` Chats tab, Settings › Chats
- **Related:** [IAMichan/Nook#533](https://github.com/IAMichan/Nook/pull/533) (link chat apps in Nook's own way)

## Context

Settings › Chats links each chat app in Nook's own way, without a chat service:

| App | How Nook links it today | Realtime? |
| --- | --- | --- |
| WhatsApp | GOWA, a Go gateway built on `whatsmeow`, downloaded from GOWA's GitHub releases (SHA-256 checked), run as a child of Nook on `127.0.0.1` (`Services/WhatsApp/WhatsAppGOWA.swift`) | Yes (webhook) |
| Telegram | TDLib, built once per Mac by `scripts/build-tdlib.sh`, copied into `Nook.app/Contents/Frameworks` and signed with Nook's identity (`TelegramBridge.swift`) | Yes |
| Instagram | Web sign-in in Nook; a hidden `WKWebView` on the same cookies asks `/api/v1/direct_v2/inbox` every 30 s (`InstagramBridge.swift`) | No (polling) |
| Teams, Slack, Messages | Their own sign-in, token or the local Messages database | Polling |

Messenger, Signal, Discord, LinkedIn and X have no own way. In `ChatOwnLinkSteps` (`App/Settings/ChatAppSheet.swift`) they
fall through to `EmptyView()`, and the sheet only offers them when a Beeper-style local chat service answers on
`localhost:23373` (`ChatLinker`, `BeeperBridge`, `ChatLiveStream`). The owner does not want Beeper to be required.

Beeper Desktop links these apps by running the mautrix *bridgev2 network connectors* on this Mac, compiled into one
native library: `mautrix-meta` (`messagix` for the web Lightspeed protocol, `instameow` for Android-app emulation),
`mautrix-signal` (`signalmeow` on top of `libsignal`), `mautrix-twitter` (`twittermeow`), `mautrix-linkedin`
(`linkedingo`) and a Discord connector. Instagram and Messenger get realtime from Lightspeed over an MQTT WebSocket
(`gateway.instagram.com/ws/lightspeed`, `edge-chat.messenger.com` for Messenger) instead of polling.

### Facts checked on 2026-10-23

| Project | License | Commits in the last 90 days |
| --- | --- | --- |
| Nook | MIT | — |
| `mautrix/meta` (Messenger, Instagram) | AGPL-3.0 | 100+ |
| `mautrix/signal` | AGPL-3.0 | 68 |
| `signalapp/libsignal` (Rust, needed by `signalmeow` through cgo) | AGPL-3.0 | active |
| `mautrix/twitter` | AGPL-3.0 | 63 |
| `mautrix/linkedin` | AGPL-3.0 | 26 |
| `mautrix/discord` | AGPL-3.0 | 4 (the public repository is still the legacy bridge, not a bridgev2 connector) |
| `mautrix/go` (bridgev2 framework) | MPL-2.0 | active |
| `tulir/whatsmeow` | MPL-2.0 | active |
| GOWA (`aldinokemal/go-whatsapp-web-multidevice`) | MIT | active |
| TDLib | BSL-1.0 | active |

How Nook is distributed matters for every option below: Nook is built from its own git checkout on the user's Mac and
updated by rebuilding from `main` (`docs/UPDATES.md`). It is not distributed as a notarized binary today. Helpers are
either fetched at runtime (GOWA) or built locally and signed with the local identity (TDLib).

## Decision drivers

1. Beeper must stay optional; nothing may depend on Beeper's servers or app.
2. Nook's own source stays MIT.
3. The user's accounts must not be put at more risk than the app's own web or desktop client would.
4. One maintainer: whatever we add must survive protocol changes without weekly hand work in Swift.
5. Reuse what Nook already has (the GOWA pattern, the local-service client in `ChatLinker`/`BeeperBridge`/`ChatLiveStream`).

## Options

### Option 1: A Go helper (`nook-chatd`) that imports the mautrix connectors

A small Go program that imports the bridgev2 network connectors directly (no Matrix homeserver, no Matrix at all) and
exposes a local HTTP + WebSocket API on `127.0.0.1` with a per-launch token. Nook runs it as a child process, like GOWA.

The API should be the subset of the Beeper Client API Nook already speaks: `GET /v1/info`, `GET /v1/bridges`,
`/v1/bridges/{id}/login-sessions` (QR, cookie and form steps), `GET /v1/chats`, `GET /v1/chats/{id}/messages`,
send, assets, and `/v1/ws` with `chat.upserted` / `message.upserted`. Then `ChatLinker`, `BeeperBridge` and
`ChatLiveStream` work unchanged apart from a configurable base URL and port (not 23373, so it never collides with a
running Beeper), and Settings › Chats needs no new layout: "a local chat service runs" simply becomes true.

- **Covers:** Signal, Messenger, Instagram (realtime via Lightspeed, replacing the 30 s poll), X, LinkedIn. Discord only
  after porting the legacy bridge to bridgev2 or finding a maintained connector, and see ban risk below.
- **Licensing:** the connectors are AGPL-3.0, so the helper binary is a work based on them and must be AGPL-3.0, with
  its complete source available to everyone who receives it. Nook itself is not affected as long as the two stay
  separate programs that talk over a socket (an "aggregate" in GPL terms): no linking, no shared code, no copying
  connector code into Nook. The clean way is a separate public repository (`IAMichan/nook-chatd`, AGPL-3.0) that
  Nook downloads from its releases with a SHA-256 check, exactly like GOWA, or builds locally like TDLib. AGPL §13 (the
  network clause) only binds people who run a *modified* version for users over a network; a helper on `127.0.0.1`
  for the Mac's own user is satisfied by the public source. `THIRD-PARTY-NOTICES.md` gets a section for it.
- **Signing and notarization:** today none is needed. A binary Nook downloads itself carries no quarantine attribute
  (GOWA already relies on this and clears it anyway), and a child process is not subject to Nook's library
  validation. If the helper is built locally instead, sign it with Nook's identity in a build phase like
  `Config/embed-tdlib.sh`. If Nook is ever shipped as a notarized app, the helper must sit in
  `Contents/Helpers`, be signed with the same Developer ID with the hardened runtime and a secure timestamp, and be
  notarized with the app. Go binaries (including cgo with `libsignal`'s static library) sign and notarize without
  special entitlements. A downloaded helper outside the bundle would then also need its own notarized release.
- **Account-ban risk:** per app, not per option.
  - Signal: low. `signalmeow` registers as a linked device through Signal's normal QR flow, like Signal Desktop.
  - Messenger, Instagram: medium. `messagix` behaves like the web client on the user's own cookies; Meta has
    checkpointed and locked accounts that bridge, especially new accounts, new IPs and bursts of sends. Use only
    cookie login (never `instameow` password login), keep request rates near the web client's, and say so in Settings.
  - X: medium. Web-client emulation; X rate-limits and locks accounts with odd traffic.
  - LinkedIn: medium to high. LinkedIn's user agreement forbids automated access and it restricts accounts actively.
  - Discord: high. Automating a user account ("self-bot") is explicitly against Discord's terms and accounts are banned
    for it. Not worth offering.
- **Maintenance:** moderate and mostly upstream. Mau Labs and Beeper fix protocol changes in the connectors (100+ commits
  in three months for `mautrix/meta` alone); our job is bumping Go modules, rebuilding, keeping the thin API layer and
  the bridgev2 interfaces in step, and the `libsignal` Rust build (the hardest part of the build, as TDLib is for
  Telegram). bridgev2 interfaces still change between releases, so expect a small fix with most bumps. CI should build
  the helper for arm64 and x86_64 and publish checksummed releases.

### Option 2: Port parts to Swift

Write native Swift clients for the protocols, for example Instagram's Lightspeed over MQTT.

- **Covers:** whatever we port. Realistically one app (Instagram, then perhaps Messenger, which shares Lightspeed).
  Signal is out of reach: it needs `libsignal`, which is AGPL-3.0 itself, so even a Swift Signal client would pull
  AGPL code into Nook.
- **Licensing:** reading the AGPL connectors and re-typing them in Swift makes Nook a derivative work, which would force
  Nook from MIT to AGPL. A port would have to be clean-room, from watching the web client's traffic only. That is
  slow and hard to prove.
- **Signing and notarization:** none: it is Nook's own code.
- **Account-ban risk:** higher than Option 1 for the same app. A fresh implementation gets the subtle parts wrong (sync
  cursors, epoch ids, versioned request ids) that `messagix` has already learned, and odd traffic is what gets
  accounts flagged.
- **Maintenance:** high. Lightspeed is not just MQTT: it is a stream of stored-procedure calls (`LS…` tasks) whose shape
  Meta changes often. We would carry all of that alone, with no upstream.

**A cheaper variant for Instagram realtime only:** let instagram.com do the realtime. The hidden `WKWebView` in
`InstagramBridge` already loads Instagram's inbox page with the user's cookies, and that page opens the Lightspeed
socket itself. A small `WKUserScript` that notices incoming socket frames (without decoding them) and posts a
`changed` message to Nook lets Nook fetch the inbox right away instead of waiting up to 30 s, and the poll can drop to a
few minutes as a safety net. This is Nook's own MIT code, adds no new traffic pattern (it *is* the web client), and is
a day of work. It does not cover any of the five other apps.

### Option 3: Leave those apps to notifications only

Keep today's behavior: Messenger, Signal, Discord, LinkedIn and X show in the Chats tab from their macOS notifications
(when their desktop app or web push is on), and full linking only appears when a local chat service runs.

- **Covers:** read-only previews of new messages for all five; no history, no sending, no read state.
- **Licensing:** nothing new.
- **Signing and notarization:** nothing new.
- **Account-ban risk:** none.
- **Maintenance:** none beyond today.

## Comparison

| | Option 1: Go helper | Option 2: Swift port | Option 3: Notifications |
| --- | --- | --- | --- |
| Signal | Full | No (`libsignal` is AGPL) | Previews |
| Messenger | Full, realtime | Possible, large | Previews |
| Instagram realtime | Yes (Lightspeed) | Yes; or the web-page variant | No (30 s poll stays) |
| X | Full | No | Previews |
| LinkedIn | Full | No | Previews |
| Discord | Only after porting the legacy bridge; not advised | No | Previews |
| Nook stays MIT | Yes, helper is a separate AGPL program | Only with a clean-room port | Yes |
| Signing | None today; Developer ID + notarization if Nook ever ships notarized | None | None |
| Ban risk | Same as the official web/desktop client, done well | Higher | None |
| Maintenance | Moderate, mostly upstream | High, all ours | None |

## Decision

**Adopt Option 1, as a helper with its own AGPL-3.0 license kept in this repository (`apps/chatd`), and do the Option 2
web-page variant for Instagram first. Keep Option 3 as the fallback for every app the helper does not link. Do not offer
Discord.**

In order:

1. **Instagram realtime now, in Nook (MIT):** add the socket-watching `WKUserScript` to `InstagramBridge` so the inbox is
   read as soon as instagram.com's own page receives something; lower the poll to a safety net.
2. **`apps/chatd` (AGPL-3.0):** a Go program, nook-chatd, importing `mautrix/go` bridgev2 and the Signal, Meta
   (Messenger and Instagram), X and LinkedIn connectors, serving the Beeper-Client-API subset listed above on
   `127.0.0.1` with a token.
3. **In Nook:** built locally by `scripts/build-chatd.sh` and embedded and signed by a build phase, exactly like TDLib;
   a process runner (`ChatHelper`); the base URL and token in `ChatLinker`, `BeeperBridge` and `ChatLiveStream` come
   from whichever service runs (Nook's helper first, Beeper second). The existing login-session flow in Settings ›
   Chats takes over from there. A `THIRD-PARTY-NOTICES.md` section says the helper is a separate AGPL program.
4. **Logins:** Signal by QR code, the others by signing in on the app's own website in Nook's sign-in window (cookies,
   and for LinkedIn two request headers its page sets); never a password typed into Nook. Messenger, Instagram, X and
   LinkedIn show a clear "may get your account restricted" note before linking.
5. **Discord stays on notifications.** Revisit only if Discord ever allows user-account clients.

### Why one repository after all

The options above assumed a separate public repository with its own release pipeline. Nook is only ever built from its
own checkout, so the helper is built the same way as TDLib: from source, on the Mac that runs it. Keeping it in
`apps/chatd` with its own `LICENSE` (AGPL-3.0) keeps the licenses apart just as well, since it is still a separate
program that shares no code with Nook, and it saves a second repository, CI and checksummed downloads.

## Consequences

- Nook links every requested app except Discord without Beeper, using the same code paths it already has for a local
  chat service, so the UI does not grow a second flow.
- Nook's source stays MIT. `apps/chatd` is AGPL-3.0 and its source is in this repository; nobody may copy connector code
  into Nook's own sources.
- One more local build step (`scripts/build-chatd.sh`, about two minutes for libsignal the first time). Most protocol
  fixes come from upstream; we bump the connector versions and rebuild.
- If Nook is ever distributed as a notarized app, the helper has to be signed and notarized with it (see Option 1).
- Account risk is the user's choice per app and is stated where they link it.

## Implementation

- `apps/chatd`: `networks.go` (one bridgev2 bridge per app), `matrix.go` (`LocalMatrix`, the Matrix side the bridges
  talk to, with no server), `store.go` (rooms, members, timeline, media in SQLite), `login.go` (login sessions),
  `api.go` and `live.go` (the API and `/v1/ws`), `main.go`.
- Nook: `Services/Messages/ChatHelper.swift`, `Config/embed-chatd.sh`, the base URL and token switch in
  `BeeperBridge`/`ChatLinker`, header collection in `ChatSignInWindow`, required-field handling in `ChatLinkData`, and
  the live-line nudge in `InstagramBridge`.
- Verified: every app starts and offers a login step Nook can show (Signal a QR code; the others their website), the
  helper signed with the hardened runtime runs, and the store logic has Go tests. Not verified: linking real accounts
  end to end, which needs your own accounts.
