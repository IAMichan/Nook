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

## Turning it on

In Nook on the Mac: **Settings › Devices › Away from home › Reach this Mac away from home**.

- **Nook's relay** (the default when the build carries one): nothing else to do.
- **Your own relay** on a free Cloudflare account, without a command line: click **Open Cloudflare**, sign in (or
  create an account), create the token that is filled in for you, paste it in Nook and click **Set up**. Nook uploads
  this relay (it ships inside the app), turns on its `workers.dev` address and switches to it, and updates it when a
  new Nook version brings new relay code.

Phones that are already paired pick up the relay the next time they connect at home; a new pairing code carries it.
To stop, turn the switch off. To remove your own relay, delete the `nook-relay` Worker in the Cloudflare dashboard.

## Deploying it yourself

Nook's own relay is deployed by `.github/workflows/relay-deploy.yml` (repository secrets `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID`; then set the repository variable `NOOK_RELAY_URL` to the address it prints, and release builds
carry it). By hand:

```sh
cd apps/relay
npx wrangler@4 login
npx wrangler@4 deploy       # prints the address, e.g. https://nook-relay.<you>.workers.dev
```

and enter the address in Nook under *I already have a relay*.

## Push through the relay

With Nook's APNs key set as Worker secrets, the relay also delivers notifications for Macs that have no Apple
developer account of their own (`worker/push.js`, docs/COMPANION.md "Push through Nook's relay"). The Mac posts the
phone's device token and the notification **sealed with that phone's pairing key**; the relay signs an APNs request
and passes the blob on unread, with a generic "Nook needs you" as the visible text. The phone's Notification Service
Extension opens the blob and shows the real title and text. The relay limits pushes per room and per device token, and
logs nothing.

```sh
npx wrangler@4 secret put APNS_KEY        # the .p8 from developer.apple.com › Keys (Apple Push Notifications service)
npx wrangler@4 secret put APNS_KEY_ID     # its key id
npx wrangler@4 secret put APNS_TEAM_ID    # the team that owns the companion app's bundle id
npx wrangler@4 secret put APNS_TOPIC      # optional: the companion's bundle id if it is not nl.imdigital.nook.companion
```

Without them `POST /v1/push` answers 501 and the Mac says so in Settings. The key must belong to the team that signs
the companion app the phones run (pushes for another bundle id are refused by Apple).

`POST /v1/push` takes `{"room": "<32 hex>", "token": "<hex>", "production": true, "sealed": {"d": "…", "s": "…"},
"collapse": "<hex>", "urgent": false}` and answers `{"apns": <Apple's status>, "reason": "…"}`, or 400 (bad request),
413 (too large), 429 (over the limit), 501 (not set up), 502 (Apple unreachable).

## Develop

```sh
npm test                    # the room logic, the message format and the push endpoint (node:test)
npx wrangler@4 dev          # a local relay at http://localhost:8787 (the Mac accepts http only for localhost)
```

| Path | |
|---|---|
| `GET /v1/rooms/<32 hex>?role=mac` | the Mac's WebSocket; a newer one replaces the older |
| `GET /v1/rooms/<32 hex>?role=phone` | a phone's WebSocket; closed with 4404 when the Mac is not connected |
| `POST /v1/push` | a push for a paired phone (opt-in, below) |
| `GET /health` | `Nook relay` |

Messages on the Mac's socket are `[kind: 1 byte][connection: 4 bytes][payload]` (`worker/mux.js`, and `RelayMux` in
`packages/protocol/Sources/CompanionRelay.swift`): `1` a phone connected, `2` bytes for or from that connection, `3`
it closed. A phone's own socket carries the payload alone. A room holds 8 phone connections at most.
