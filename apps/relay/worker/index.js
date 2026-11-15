import { DurableObject } from "cloudflare:workers";
import { isRoom } from "./mux.js";
import { guestResponse } from "./guest.js";
import { HookLogic, answerResponse, isHook, mayListen, readLimited } from "./hooks.js";
import { TunnelLogic, mayListenMCP, routeMCP } from "./mcp.js";
import { admit, handlePush } from "./push.js";
import { RoomLogic } from "./room.js";

// Nook's relay (docs/COMPANION.md, "Away from home"): lets the iPhone companion reach Nook on a Mac from anywhere,
// without Tailscale and without a port opened on the router. The Mac keeps one outgoing WebSocket per paired phone;
// the phone connects to the same room; bytes pass between them. Everything is sealed end to end with the pairing key,
// so this Worker can read and forge nothing.
//
//   GET /v1/rooms/<32 hex>?role=mac|phone   (WebSocket)
//   POST /v1/push                            (opt-in, push.js: needs the APNS_* secrets)
//   GET /v1/guest                            (a guest link's page, guest.js: it talks to the Mac through a room, sealed)
//   GET /v1/hooks/<32 hex>/listen            (WebSocket, hooks.js: the Mac, with its token as bearer)
//   POST /v1/hooks/<32 hex>/<task id>        (a webhook for a scheduled task; not sealed, see hooks.js)
//   GET /v1/mcp/<32 hex>/listen              (WebSocket, mcp.js: the Mac, with its token as bearer)
//   * /v1/mcp/<32 hex>[/…]                   (Nook's tools for a cloud assistant over MCP, with OAuth; not sealed, see mcp.js)
//   GET /.well-known/<oauth document>/v1/mcp/<32 hex>

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/health") {
      return new Response("Nook relay\n", { headers: { "content-type": "text/plain" } });
    }
    if (url.pathname === "/v1/guest") return guestResponse(request);
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
    const mcp = routeMCP(url.pathname);
    if (mcp) {
      const room = env.ROOMS.get(env.ROOMS.idFromName("mcp:" + mcp.room));
      if (mcp.path === "/listen") {
        if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket\n", { status: 426 });
        const token = request.headers.get("Authorization")?.replace(/^Bearer /, "");
        if (!(await mayListenMCP(token, mcp.room))) return new Response("Not allowed\n", { status: 403 });
        return room.fetch("https://mcp/listen", request);
      }
      // The path goes along in a header: the room's own URL only says it is for the tunnel.
      const forwarded = new Request("https://mcp/deliver" + url.search, request);
      forwarded.headers.set("x-nook-mcp-path", mcp.path);
      return room.fetch(forwarded);
    }
    const hook = url.pathname.match(/^\/v1\/hooks\/([^/]+)\/([^/]+)$/);
    if (hook) {
      if (!isRoom(hook[1])) return new Response("Not found\n", { status: 404 });
      const room = env.ROOMS.get(env.ROOMS.idFromName("hooks:" + hook[1]));
      if (hook[2] === "listen") {
        if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("Expected a WebSocket\n", { status: 426 });
        const token = request.headers.get("Authorization")?.replace(/^Bearer /, "");
        if (!(await mayListen(token, hook[1]))) return new Response("Not allowed\n", { status: 403 });
        return room.fetch("https://hooks/listen", request);
      }
      if (request.method !== "POST") return new Response("POST only\n", { status: 405 });
      if (!isHook(hook[2])) return new Response("Not found\n", { status: 404 });
      // Bounded here, before anything reaches the room that holds the Mac's socket.
      const body = await readLimited(request);
      if (body === null) return new Response("too large\n", { status: 413 });
      return room.fetch("https://hooks/deliver/" + hook[2], { method: "POST", headers: request.headers, body });
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
    this.hooks = new HookLogic(ctx);
    this.tunnel = new TunnelLogic(ctx);
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
    if (url.hostname === "mcp") {
      if (url.pathname === "/listen") {
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);
        this.tunnel.listen(server);
        return new Response(null, { status: 101, webSocket: client });
      }
      return this.tunnel.deliver(request, request.headers.get("x-nook-mcp-path") ?? "/");
    }
    if (url.hostname === "hooks") {
      if (url.pathname === "/listen") {
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);
        this.hooks.listen(server);
        return new Response(null, { status: 101, webSocket: client });
      }
      const body = await request.arrayBuffer();
      const answer = await this.hooks.deliver({ hook: url.pathname.split("/").pop(), headers: request.headers, body });
      return answerResponse(answer);
    }
    const role = url.searchParams.get("role");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.logic.accept(server, role);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    if (this.ctx.getTags(ws).includes("hooks")) return this.hooks.message(message);
    if (this.ctx.getTags(ws).includes("mcp")) return this.tunnel.message(message);
    this.logic.message(ws, message);
  }

  async webSocketClose(ws, code, reason) {
    this.closed(ws);
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      // Already closed.
    }
  }

  async webSocketError(ws) {
    this.closed(ws);
  }

  /** A socket went away: a room tells the other side, a tunnel fails what waits for an answer on it. */
  closed(ws) {
    const tags = this.ctx.getTags(ws);
    if (tags.includes("hooks")) this.hooks.closed(ws);
    else if (tags.includes("mcp")) this.tunnel.closed(ws);
    else this.logic.closed(ws);
  }
}
