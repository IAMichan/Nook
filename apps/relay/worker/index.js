import { DurableObject } from "cloudflare:workers";
import { isRoom } from "./mux.js";
import { RoomLogic } from "./room.js";

// Nook's relay (docs/COMPANION.md, "Away from home"): lets the iPhone companion reach Nook on a Mac from anywhere,
// without Tailscale and without a port opened on the router. The Mac keeps one outgoing WebSocket per paired phone;
// the phone connects to the same room; bytes pass between them. Everything is sealed end to end with the pairing key,
// so this Worker can read and forge nothing.
//
//   GET /v1/rooms/<32 hex>?role=mac|phone   (WebSocket)

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("Nook relay\n", { headers: { "content-type": "text/plain" } });
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
    const role = new URL(request.url).searchParams.get("role");
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
