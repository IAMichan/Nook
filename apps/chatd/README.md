# nook-chatd

Nook's own chat helper. It links **WhatsApp, Telegram, Signal, Messenger, Instagram, X, LinkedIn and Slack** on this Mac, without Beeper, and
serves them to Nook's Chats tab. Licensed under the **AGPL-3.0** (see [LICENSE](LICENSE)), separate from Nook's MIT
license, because it is built on the [mautrix](https://github.com/mautrix) bridgev2 network connectors. Why and how:
[docs/ADR-CHAT-LINKS.md](../../docs/ADR-CHAT-LINKS.md).

## How it works

- Each app runs as its own bridgev2 bridge (`networks.go`) with its own SQLite database in
  `~/Library/Application Support/Nook/ChatHelper`.
- There is no Matrix server. `LocalMatrix` (`matrix.go`) answers in its place and keeps rooms, members, messages,
  reactions and media in `chats.db` (`store.go`). You are the one local user (`@me:nook.local`), a double puppet, so
  your own messages from other devices show as yours.
- `api.go` serves the part of Beeper's Client API that Nook already reads (`/v1/bridges`, login sessions, `/v1/chats`,
  messages, send, edit, delete, reactions, read/unread, pin, mute, archive, assets) and `live.go` the `/v1/ws` live line.
  `POST /v1/chats/{chat}/paginate` brings in a chat's next batch of older messages when you scroll back, as Beeper does
  (the bridges' manual backfill).
  It listens on `127.0.0.1` only, behind a token Nook makes at each start (`NOOK_CHATD_TOKEN`).
- Logins (`login.go`) use a QR code (WhatsApp, Signal), the app's own website in Nook's sign-in window (Instagram, Messenger,
  X, LinkedIn, Slack: there the step's own script finds the token in the page, served as a `special` field with
  `extractJS`), or fields Nook shows (Telegram: your phone number, the code Telegram sends, then your 2FA password if
  you set one, as on a new phone). WhatsApp (mautrix-whatsapp) asks the phone for a year of history when it is linked
  and for older messages when you scroll back to them. Telegram's connector (mautrix-telegram, with its own Go copy of gotd) needs no TDLib.
- Telegram needs an app id and hash from my.telegram.org. Nook passes the ones its build comes with (Info.plist keys
  `NookTelegramAPIID` / `NookTelegramAPIHash`) or your own from Settings as `NOOK_TELEGRAM_API_ID` /
  `NOOK_TELEGRAM_API_HASH`; without them `/v1/bridges` lists Telegram as unavailable and says why.
- It stops by itself when Nook, its parent process, is gone.

## Building

```bash
scripts/build-chatd.sh
```

Needs Homebrew's `go` and `protobuf`, and Rust (`rustup`): Signal needs libsignal's Rust library, built at the commit
the Signal connector pins. The result goes to `apps/macos/Vendor/ChatHelper/nook-chatd`; the next Nook build copies it
into `Nook.app/Contents/Helpers` and signs it (`apps/macos/Config/embed-chatd.sh`).

## Testing

```bash
cd apps/chatd && CGO_LDFLAGS="-L$(pwd)/../../.build/chatd/libsignal/target/release" go test ./...
```

## Updating the connectors

Bump the `go.mau.fi/mautrix-*` versions in `go.mod`, keep the `github.com/imroc/req/v3` replace in step with the one in
mautrix-meta's own `go.mod`, run `go mod tidy`, then `scripts/build-chatd.sh` (it rebuilds libsignal when the Signal
connector pins a new commit).
