// Push for everyone (docs/COMPANION.md, "Push through Nook's relay"): the Mac posts a phone's device token and a blob
// sealed with that phone's pairing key; the relay signs an APNs request with Nook's own APNs key (worker secrets) and
// passes the blob on unread. The phone's Notification Service Extension opens it and writes the real title and text;
// Apple and the relay only ever see "Nook needs you". Opt-in: without the APNS_* secrets the endpoint answers 501.
//
//   POST /v1/push   {"room", "token", "production", "sealed": {"d", "s"}, "collapse"?, "urgent"?}
//
// Nothing here logs: no rooms, tokens or blobs.

import { isRoom } from "./mux.js";

/** Requests per window, per room (one paired phone of one Mac) and per device token (a phone paired with several Macs). */
export const PUSH_LIMITS = {
  room: { perMinute: 12, perHour: 120 },
  token: { perMinute: 20, perHour: 240 },
};
/** The request body; a sealed notification is a few hundred bytes. */
export const MAX_BODY = 8 * 1024;
/** What APNs accepts for an alert. */
export const MAX_PAYLOAD = 4096;
export const DEFAULT_TOPIC = "nl.imdigital.nook.companion";
/** The generic text Apple sees; the phone replaces it with the sealed one. */
export const GENERIC_ALERT = { title: "Nook", body: "Nook needs you" };

const HEX = /^[0-9a-f]+$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;

/** True when the worker holds Nook's APNs key: the endpoint is on. */
export function pushConfigured(env) {
  return Boolean(env?.APNS_KEY && env?.APNS_KEY_ID && env?.APNS_TEAM_ID);
}

/** Checks a request body (already parsed JSON); `{ value }` or `{ error }`. */
export function parsePushRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "not an object" };
  const { room, token, production, sealed, collapse, urgent } = body;
  if (!isRoom(room)) return { error: "room" };
  if (typeof token !== "string" || token.length < 32 || token.length > 200 || !HEX.test(token.toLowerCase())) {
    return { error: "token" };
  }
  if (typeof production !== "boolean") return { error: "production" };
  if (!sealed || typeof sealed !== "object" || typeof sealed.d !== "string" || typeof sealed.s !== "string") {
    return { error: "sealed" };
  }
  if (!/^[0-9a-f]{16}$/.test(sealed.d) || sealed.s.length < 40 || sealed.s.length > 3000 || !BASE64.test(sealed.s)) {
    return { error: "sealed" };
  }
  if (collapse !== undefined && (typeof collapse !== "string" || !/^[0-9a-f]{1,64}$/.test(collapse))) {
    return { error: "collapse" };
  }
  if (urgent !== undefined && typeof urgent !== "boolean") return { error: "urgent" };
  return {
    value: { room, token: token.toLowerCase(), production, sealed: { d: sealed.d, s: sealed.s }, collapse, urgent: urgent === true },
  };
}

/** The alert Apple delivers: generic text, mutable so the extension can rewrite it, and the sealed blob. */
export function apnsPayload(request) {
  return {
    aps: {
      alert: GENERIC_ALERT,
      sound: "default",
      "mutable-content": 1,
      "content-available": 1,
      "interruption-level": request.urgent ? "time-sensitive" : "active",
    },
    "nook-sealed": request.sealed,
  };
}

/**
 * A fixed-window limiter: at most `perMinute` in the current minute and `perHour` in the current hour.
 * `state` is what the last call returned (or nothing); returns `{ allowed, state }`.
 */
export function admit(state, now, limits) {
  const minute = Math.floor(now / 60);
  const hour = Math.floor(now / 3600);
  const next = {
    minute,
    minuteCount: state?.minute === minute ? state.minuteCount : 0,
    hour,
    hourCount: state?.hour === hour ? state.hourCount : 0,
  };
  if (next.minuteCount >= limits.perMinute || next.hourCount >= limits.perHour) return { allowed: false, state: next };
  next.minuteCount += 1;
  next.hourCount += 1;
  return { allowed: true, state: next };
}

function base64url(bytes) {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : new Uint8Array(bytes);
  let text = "";
  for (const byte of data) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem) {
  const body = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "").replace(/\s+/g, "");
  const raw = atob(body);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

/** Hex SHA-256 of a text: the token's limiter name, so the token itself never names anything. */
export async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** APNs refuses tokens older than an hour and new ones more often than every 20 minutes: one per 50 minutes. */
export const TOKEN_LIFETIME = 50 * 60;
const signed = { token: null, issued: 0, kid: null };

/** The ES256 JWT for token-based APNs authentication, reused for 50 minutes. */
export async function apnsJWT(env, now, cache = signed) {
  if (cache.token && cache.kid === env.APNS_KEY_ID && now - cache.issued < TOKEN_LIFETIME) return cache.token;
  const header = base64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = base64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(env.APNS_KEY), { name: "ECDSA", namedCurve: "P-256" }, false, [
    "sign",
  ]);
  // WebCrypto signs ECDSA as r||s, which is what a JWT wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`));
  cache.token = `${header}.${claims}.${base64url(signature)}`;
  cache.issued = now;
  cache.kid = env.APNS_KEY_ID;
  return cache.token;
}

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

/**
 * Handles POST /v1/push. `deps`: `fetch` (to APNs), `limit(name, limits)` → Promise<boolean> (a Durable Object per
 * room and per token), `now()` in seconds, and the JWT cache. Answers 200 `{"apns": status, "reason"?}` once Apple
 * answered, 400 for a bad request, 413 too large, 429 over the limit, 501 when push is not set up, 502 when Apple
 * could not be reached.
 */
export async function handlePush(request, env, deps) {
  if (!pushConfigured(env)) return json(501, { error: "push is not set up on this relay" });
  if (request.method !== "POST") return json(405, { error: "POST only" });
  const length = Number(request.headers.get("content-length") ?? 0);
  if (length > MAX_BODY) return json(413, { error: "too large" });
  const text = await request.text();
  if (text.length > MAX_BODY) return json(413, { error: "too large" });
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return json(400, { error: "not JSON" });
  }
  const parsed = parsePushRequest(body);
  if (parsed.error) return json(400, { error: parsed.error });
  const push = parsed.value;

  const payload = JSON.stringify(apnsPayload(push));
  if (new TextEncoder().encode(payload).byteLength > MAX_PAYLOAD) return json(413, { error: "too large" });

  const tokenName = `push:${await sha256Hex(push.token)}`;
  if (!(await deps.limit(`push-room:${push.room}`, PUSH_LIMITS.room)) || !(await deps.limit(tokenName, PUSH_LIMITS.token))) {
    return json(429, { error: "slow down" });
  }

  const now = deps.now();
  const host = push.production ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const headers = {
    authorization: `bearer ${await apnsJWT(env, now, deps.cache)}`,
    "apns-topic": env.APNS_TOPIC || DEFAULT_TOPIC,
    "apns-push-type": "alert",
    "apns-priority": push.urgent ? "10" : "5",
    "content-type": "application/json",
  };
  if (push.collapse) headers["apns-collapse-id"] = push.collapse;
  let response;
  try {
    response = await deps.fetch(`https://${host}/3/device/${push.token}`, { method: "POST", headers, body: payload });
  } catch {
    return json(502, { error: "apns unreachable" });
  }
  let reason;
  if (response.status !== 200) {
    try {
      reason = (await response.json())?.reason;
    } catch {
      reason = undefined;
    }
    // A rejected key must not stay cached.
    if (response.status === 403) (deps.cache ?? signed).token = null;
  }
  return json(200, reason ? { apns: response.status, reason: String(reason).slice(0, 64) } : { apns: response.status });
}
