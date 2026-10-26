# Nook relay

Lets **Nook Companion** on your iPhone reach Nook on your Mac from anywhere (a café, a train, mobile data) without
Tailscale and without opening a port on your router. See [docs/COMPANION.md](../../docs/COMPANION.md#away-from-home).

How it works:

- Nook on the Mac keeps one outgoing WebSocket to the relay for every paired phone, in a room only that Mac and that
  phone know (derived from their pairing key).
- When the phone cannot reach the Mac directly, it opens a WebSocket to the same room, and the relay passes bytes
  between the two.
- Everything that passes is already sealed with the pairing key (ChaCha20-Poly1305). The relay cannot read session
  titles, messages or commands, and cannot forge or change a request. It sees only which room talks, when, and how much.

It is a [Cloudflare Worker](https://developers.cloudflare.com/workers/) with one
[Durable Object](https://developers.cloudflare.com/durable-objects/) per room. An idle connection costs nothing: the
keep-alive is answered without waking the room. Personal use fits in Cloudflare's free plan.

## Deploy (once)

You need a free Cloudflare account and Node.js.

```sh
cd apps/relay
npx wrangler@4 login        # opens the browser to sign in to Cloudflare
npx wrangler@4 deploy       # prints the address, e.g. https://nook-relay.<you>.workers.dev
```

Then on the Mac: **Settings › Devices › iPhone Companion**, turn on **Reach this Mac away from home** and paste the
address. Phones that are already paired pick up the relay the next time they connect at home; a new pairing code
carries it too.

To stop using it, turn the switch off on the Mac. To remove it, delete the `nook-relay` Worker in the Cloudflare
dashboard.

## Develop

```sh
npm test                    # the room logic and the message format (node:test)
npx wrangler@4 dev          # a local relay at http://localhost:8787 (the Mac accepts http only for localhost)
```

| Path | |
|---|---|
| `GET /v1/rooms/<32 hex>?role=mac` | the Mac's WebSocket; a newer one replaces the older |
| `GET /v1/rooms/<32 hex>?role=phone` | a phone's WebSocket; closed with 4404 when the Mac is not connected |
| `GET /health` | `Nook relay` |

Messages on the Mac's socket are `[kind: 1 byte][connection: 4 bytes][payload]` (`src/mux.js`, and `RelayMux` in
`packages/protocol/Sources/CompanionRelay.swift`): `1` a phone connected, `2` bytes for or from that connection, `3`
it closed. A phone's own socket carries the payload alone. A room holds 8 phone connections at most.
