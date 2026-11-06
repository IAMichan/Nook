// Webhooks for scheduled tasks, from the internet to a Mac (docs/WORKSPACE-AGENTS.md). The Mac keeps one outgoing
// WebSocket; a POST is passed to it and the Mac's answer goes back to the sender. Unlike the companion's traffic these
// bodies are not sealed: a sender such as GitHub only speaks plain HTTPS, so the relay passes them readable. It stores
// none of it. The Mac checks each request's signature itself, with a secret the relay never sees.

/** The largest body passed on, as on the Mac (WebhookHTTP.maxBodyBytes). */
export const MAX_BODY = 256 * 1024;
/** How long a sender waits for the Mac. */
export const ANSWER_TIMEOUT_MS = 10_000;
/** Requests that may wait for the Mac at once. */
export const MAX_WAITING = 16;

const LISTEN_LABEL = "nook-webhook-room";
const HEADERS = ["x-hub-signature-256", "x-nook-signature-256", "x-nook-delivery", "x-github-delivery", "idempotency-key"];

/** The room a listening token belongs to: the first 32 hex of an HMAC, so the public URL does not give the token away. */
export async function roomOf(token) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(token), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(LISTEN_LABEL)));
  return [...signed].map((byte) => byte.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

/** Whether `token` may listen in `room`. */
export async function mayListen(token, room) {
  return typeof token === "string" && token.length >= 32 && (await roomOf(token)) === room;
}

/** A task's hook: a UUID, as on the Mac (WebhookHTTP.taskID). */
export function isHook(text) {
  return typeof text === "string" && /^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(text);
}

function base64(bytes) {
  let text = "";
  for (let start = 0; start < bytes.length; start += 0x8000) text += String.fromCharCode(...bytes.subarray(start, start + 0x8000));
  return btoa(text);
}

/** The Mac's socket and the requests that wait for it. Waiting requests hold the object awake, so memory is enough. */
export class HookLogic {
  /** @param {{ getWebSockets(tag?: string): any[], acceptWebSocket(ws: any, tags: string[]): void }} sockets */
  constructor(sockets, { timeoutMs = ANSWER_TIMEOUT_MS, newID = () => crypto.randomUUID() } = {}) {
    this.sockets = sockets;
    this.timeoutMs = timeoutMs;
    this.newID = newID;
    /** @type {Map<string, (answer: {status: number, message: string}) => void>} */
    this.waiting = new Map();
  }

  listen(ws) {
    for (const old of this.sockets.getWebSockets("hooks")) {
      try {
        old.close(4000, "replaced");
      } catch {
        // Already closed.
      }
    }
    this.sockets.acceptWebSocket(ws, ["hooks"]);
  }

  /** What to answer a POST: `{status, message}`. */
  async deliver({ hook, headers, body }) {
    if (body.byteLength > MAX_BODY) return { status: 413, message: "too large" };
    // A replaced socket can still be listed while it closes.
    const mac = this.sockets.getWebSockets("hooks").find((socket) => socket.readyState === undefined || socket.readyState === 1);
    if (!mac) return { status: 503, message: "the Mac is not reachable" };
    if (this.waiting.size >= MAX_WAITING) return { status: 429, message: "too many requests" };
    const id = this.newID();
    const passed = {};
    for (const name of HEADERS) {
      const value = headers.get(name);
      if (value) passed[name] = value;
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        resolve({ status: 504, message: "the Mac did not answer" });
      }, this.timeoutMs);
      this.waiting.set(id, (answer) => {
        clearTimeout(timer);
        this.waiting.delete(id);
        resolve(answer);
      });
      try {
        mac.send(JSON.stringify({ id, path: `/hooks/${hook}`, headers: passed, body: base64(new Uint8Array(body)) }));
      } catch {
        this.waiting.get(id)?.({ status: 503, message: "the Mac is not reachable" });
      }
    });
  }

  /** The Mac's answer to a request. */
  message(text) {
    let answer;
    try {
      answer = JSON.parse(text);
    } catch {
      return;
    }
    if (typeof answer?.id !== "string" || !Number.isInteger(answer.status)) return;
    const status = answer.status >= 200 && answer.status <= 599 ? answer.status : 502;
    this.waiting.get(answer.id)?.({ status, message: String(answer.message ?? "").slice(0, 200) });
  }
}
