// Nook in another app (remote MCP, docs/WORKSPACE-AGENTS.md "Nook in another app"): a cloud assistant such as Claude.ai or
// ChatGPT reaches Nook's tools on a Mac over HTTPS. The Mac keeps one outgoing WebSocket with a token; the public address
// names a room derived from that token, so whoever has the address can call it but never listen. Each HTTP request is passed
// to the Mac and its answer goes back. The Mac does everything else: OAuth sign-in with a code shown in Nook, the grants and
// their levels, and every tool call through Nook's approvals.
//
// An assistant speaks plain HTTPS, so like webhooks (hooks.js) these bodies and the bearer tokens in them are readable to the
// relay: it stores and logs none of them. The Mac keeps only hashes of the tokens it hands out.

import { NULL_BODY, listenerOf, readLimited } from "./hooks.js";

export const MCP_LABEL = "nook-mcp-room";
/** The largest request body passed on. */
export const MAX_REQUEST = 1024 * 1024;
/** How long a caller waits for the Mac; a tool call can wait for your approval in Nook. */
export const ANSWER_TIMEOUT_MS = 290_000;
/** Requests that may wait for the Mac at once. */
export const MAX_WAITING = 32;

const REQUEST_HEADERS = ["authorization", "content-type", "accept", "mcp-protocol-version", "mcp-session-id", "last-event-id"];
const ANSWER_HEADERS = [
  "content-type", "www-authenticate", "location", "cache-control", "mcp-session-id", "content-security-policy",
  "referrer-policy", "x-frame-options", "x-content-type-options", "access-control-allow-origin",
  "access-control-allow-headers", "access-control-allow-methods", "access-control-expose-headers",
];
const WELL_KNOWN = ["oauth-protected-resource", "oauth-authorization-server", "openid-configuration"];

/** The room a listening token belongs to: the first 32 hex of an HMAC, so the public address does not give the token away. */
export async function mcpRoomOf(token) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(token), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(MCP_LABEL)));
  return [...signed].map((byte) => byte.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

export async function mayListenMCP(token, room) {
  return typeof token === "string" && token.length >= 32 && (await mcpRoomOf(token)) === room;
}

/**
 * Which room and path an address is for, or null. `/v1/mcp/<room>` is the MCP endpoint, `/v1/mcp/<room>/<rest>` the sign-in;
 * the OAuth discovery documents may also be asked for at `/.well-known/<name>/v1/mcp/<room>` (RFC 8414 and RFC 9728).
 */
export function routeMCP(pathname) {
  const direct = pathname.match(/^\/v1\/mcp\/([0-9a-f]{32})(\/.*)?$/);
  if (direct) return { room: direct[1], path: direct[2] ?? "/" };
  const known = pathname.match(/^\/\.well-known\/([a-z-]+)\/v1\/mcp\/([0-9a-f]{32})\/?$/);
  if (known && WELL_KNOWN.includes(known[1])) return { room: known[2], path: "/.well-known/" + known[1] };
  return null;
}

function base64(bytes) {
  let text = "";
  for (let start = 0; start < bytes.length; start += 0x8000) text += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
  return btoa(text);
}

function unbase64(text) {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

/** The request as the Mac gets it. */
export async function packRequest(request, path, id) {
  const url = new URL(request.url);
  const body = request.method === "GET" || request.method === "HEAD" ? new ArrayBuffer(0) : await readLimited(request, MAX_REQUEST);
  if (body === null) return null;
  const headers = {};
  for (const name of REQUEST_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers[name] = value;
  }
  return { id, method: request.method, path, query: url.search.slice(1), headers, body: base64(new Uint8Array(body)) };
}

/** The Mac's answer as a Response: only the headers it may set. An answer that cannot be one (bad base64) is a 502. */
export function unpackAnswer(answer) {
  const headers = new Headers();
  for (const name of ANSWER_HEADERS) {
    const value = answer.headers?.[name];
    if (typeof value !== "string") continue;
    try {
      headers.set(name, value);
    } catch {
      // Not a valid header value (a line break, say): left out.
    }
  }
  const status = Number.isInteger(answer.status) && answer.status >= 200 && answer.status <= 599 ? answer.status : 502;
  try {
    const body = NULL_BODY.has(status) ? null : unbase64(typeof answer.body === "string" ? answer.body : "");
    return new Response(body, { status, headers });
  } catch {
    return text(502, "Nook sent an answer that could not be read.");
  }
}

const UNREACHABLE = { status: 503, headers: { "content-type": "text/plain" }, body: btoa("Nook on this Mac is not reachable.") };

/** The Mac's socket and the requests that wait for it. Waiting requests hold the object awake, so memory is enough. */
export class TunnelLogic {
  /** @param {{ getWebSockets(tag?: string): any[], acceptWebSocket(ws: any, tags: string[]): void }} sockets */
  constructor(sockets, { timeoutMs = ANSWER_TIMEOUT_MS, newID = () => crypto.randomUUID() } = {}) {
    this.sockets = sockets;
    this.timeoutMs = timeoutMs;
    this.newID = newID;
    /** @type {Map<string, {via: string | undefined, done: (answer: object) => void}>} */
    this.waiting = new Map();
  }

  listen(ws) {
    for (const old of this.sockets.getWebSockets("mcp")) {
      try {
        old.close(4000, "replaced");
      } catch {
        // Already closed.
      }
      this.closed(old);
    }
    this.sockets.acceptWebSocket(ws, ["mcp"]);
    ws.serializeAttachment?.({ listener: crypto.randomUUID() });
  }

  /** A Mac socket went away: the Mac answers on the socket a request came by, so what waits for it gets no answer. */
  closed(ws) {
    const listener = listenerOf(ws);
    for (const { via, done } of [...this.waiting.values()]) {
      if (via === listener) done(UNREACHABLE);
    }
  }

  /** The Mac's open socket; a replaced one can still be listed while it closes. */
  mac() {
    return this.sockets.getWebSockets("mcp").find((socket) => socket.readyState === undefined || socket.readyState === 1);
  }

  /** Passes `request` to the Mac and answers with what it says. */
  async deliver(request, path) {
    if (!this.mac()) return text(503, "Nook on this Mac is not reachable. Is the Mac on and Nook open?");
    if (this.waiting.size >= MAX_WAITING) return text(429, "Too many requests at once.");
    const id = this.newID();
    const packed = await packRequest(request, path, id);
    if (!packed) return text(413, "Too large.");
    // Reading the body took time: other requests may have taken the places, and the Mac may have gone.
    if (this.waiting.size >= MAX_WAITING) return text(429, "Too many requests at once.");
    const mac = this.mac();
    if (!mac) return text(503, "Nook on this Mac is not reachable. Is the Mac on and Nook open?");
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        resolve(text(504, "Nook did not answer in time."));
      }, this.timeoutMs);
      const done = (answer) => {
        clearTimeout(timer);
        this.waiting.delete(id);
        resolve(unpackAnswer(answer));
      };
      this.waiting.set(id, { via: listenerOf(mac), done });
      try {
        mac.send(JSON.stringify(packed));
      } catch {
        done(UNREACHABLE);
      }
    });
  }

  /** The Mac's answer to a request. */
  message(data) {
    if (typeof data !== "string") return;
    let answer;
    try {
      answer = JSON.parse(data);
    } catch {
      return;
    }
    if (typeof answer?.id !== "string") return;
    this.waiting.get(answer.id)?.done(answer);
  }
}

function text(status, message) {
  return new Response(message + "\n", { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}
