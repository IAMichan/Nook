import { DurableObject } from "cloudflare:workers";
import { isRoom } from "./mux.js";
import { admit, handlePush } from "./push.js";
import { RoomLogic } from "./room.js";

// Nook's relay (docs/COMPANION.md, "Away from home"): lets the iPhone companion reach Nook on a Mac from anywhere,
// without Tailscale and without a port opened on the router. The Mac keeps one outgoing WebSocket per paired phone;
// the phone connects to the same room; bytes pass between them. Everything is sealed end to end with the pairing key,
// so this Worker can read and forge nothing.
//
//   GET /v1/rooms/<32 hex>?role=mac|phone   (WebSocket)
//   POST /v1/push                            (opt-in, push.js: needs the APNS_* secrets)

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("Nook relay\n", { headers: { "content-type": "text/plain" } });
    }
    if (url.pathname === "/v1/push") {
      return handlePush(request, env, {
        fetch: (input, init) => fetch(input, init),
        // One Durable Object per room and per token keeps the count, so the limit holds across the Worker's instances.
        limit: async (name, limits) => {
          const stub = env.ROOMS.get(env.ROOMS.idFromName(name));
          const answer = await stub.fetch("https://limit/limit", { method: "POST", body: JSON.stringify(limits) });
          return answer.status === 200;
        },
        now: () => Math.floor(Date.now() / 1000),
      });
    }
    const match = url.pathname.match(/^\/v1\/rooms\/([^/]+)$/);
    if (!match || !isRoom(match[1])) return new Response("Not found\n", { status: 404 });
    const role = url.searchParams.get("role");
    if (role !== "mac" && role !== "phone") return new Response("Unknown role\n", { status: 400 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket\n", { status: 426 });
    }
    const room = env.ROOMS.get(env.ROOMS.idFromName(match[1]));
    return room.fetch(request);
  },
};

export class Room extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.logic = new RoomLogic(ctx);
    // Keep-alives are answered without waking the room, so an idle Mac connection costs nothing.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request) {
    const url = new URL(request.url);
    // The push limiter (push.js): this object then counts pushes for one room or one token, and holds no sockets.
    if (url.pathname === "/limit") {
      const limits = await request.json();
      const result = admit(await this.ctx.storage.get("push-limit"), Math.floor(Date.now() / 1000), limits);
      await this.ctx.storage.put("push-limit", result.state);
      return new Response(null, { status: result.allowed ? 200 : 429 });
    }
    const role = url.searchParams.get("role");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.logic.accept(server, role);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    this.logic.message(ws, message);
  }

  async webSocketClose(ws, code, reason) {
    this.logic.closed(ws);
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      // Already closed.
    }
  }

  async webSocketError(ws) {
    this.logic.closed(ws);
  }
}
