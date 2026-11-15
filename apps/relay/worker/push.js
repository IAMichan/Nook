// Push for everyone (docs/COMPANION.md, "Push through Nook's relay"): the Mac posts a phone's device token and a blob
// sealed with that phone's pairing key; the relay signs an APNs request with Nook's own APNs key (worker secrets) and
// passes the blob on unread. The phone's Notification Service Extension opens it and writes the real title and text;
// Apple and the relay only ever see "Nook needs you". Opt-in: without the APNS_* secrets the endpoint answers 501.
//
//   POST /v1/push   {"room", "token", "production", "sealed": {"d", "s"}, "collapse"?, "urgent"?, "service"?}
//
// `service` "fcm" goes to an Android phone through Firebase Cloud Messaging instead (secret FCM_SERVICE_ACCOUNT, the
// JSON key of a Firebase service account): a data message with the same sealed blob, which the Android app opens and
// shows itself. Google and the relay see only the blob.
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

/** True when the worker holds Nook's APNs key. */
export function apnsConfigured(env) {
  return Boolean(env?.APNS_KEY && env?.APNS_KEY_ID && env?.APNS_TEAM_ID);
}

/** The Firebase service account the worker holds, or null. */
export function fcmAccount(env) {
  if (!env?.FCM_SERVICE_ACCOUNT) return null;
  try {
    const account = typeof env.FCM_SERVICE_ACCOUNT === "string" ? JSON.parse(env.FCM_SERVICE_ACCOUNT) : env.FCM_SERVICE_ACCOUNT;
    if (typeof account?.client_email !== "string" || typeof account?.private_key !== "string" || typeof account?.project_id !== "string") return null;
    return account;
  } catch {
    return null;
  }
}

/** True when the worker can push at all (to Apple, to Google, or both): the endpoint is on. */
export function pushConfigured(env) {
  return apnsConfigured(env) || fcmAccount(env) !== null;
}

/** An FCM registration token: letters, digits, `:`, `_` and `-`. */
const FCM_TOKEN = /^[A-Za-z0-9:_-]{100,4096}$/;

/** Checks a request body (already parsed JSON); `{ value }` or `{ error }`. */
export function parsePushRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) return { error: "not an object" };
  const { room, token, production, sealed, collapse, urgent } = body;
  const service = body.service ?? "apns";
  if (service !== "apns" && service !== "fcm") return { error: "service" };
  if (!isRoom(room)) return { error: "room" };
  if (service === "fcm") {
    if (typeof token !== "string" || !FCM_TOKEN.test(token)) return { error: "token" };
  } else if (typeof token !== "string" || token.length < 32 || token.length > 200 || !HEX.test(token.toLowerCase())) {
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
    value: {
      room, token: service === "fcm" ? token : token.toLowerCase(), production, sealed: { d: sealed.d, s: sealed.s }, collapse,
      urgent: urgent === true, service,
    },
  };
}

/** The data message Google delivers to the Android app: only the blob (and how to group it); the app shows the rest. */
export function fcmMessage(request) {
  const android = { priority: request.urgent ? "HIGH" : "NORMAL", ttl: "3600s" };
  if (request.collapse) android.collapse_key = request.collapse;
  return { message: { token: request.token, data: { "nook-sealed-d": request.sealed.d, "nook-sealed-s": request.sealed.s }, android } };
}

function pemToDerAny(pem) {
  const body = pem.replace(/-----(BEGIN|END) [A-Z ]*PRIVATE KEY-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const raw = atob(body);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

const fcmSigned = { token: null, expires: 0, email: null };

/** An OAuth access token for FCM from the service account (an RS256 JWT exchanged at Google), reused until near its end. */
export async function fcmAccessToken(account, now, fetchImpl, cache = fcmSigned) {
  if (cache.token && cache.email === account.client_email && now < cache.expires - 300) return cache.token;
  const aud = account.token_uri || "https://oauth2.googleapis.com/token";
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(
    JSON.stringify({ iss: account.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", aud, iat: now, exp: now + 3600 }),
  );
  const key = await crypto.subtle.importKey("pkcs8", pemToDerAny(account.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`));
  const assertion = `${header}.${claims}.${base64url(signature)}`;
  const response = await fetchImpl(aud, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=${encodeURIComponent("urn:ietf:params:oauth:grant-type:jwt-bearer")}&assertion=${assertion}`,
  });
  if (response.status !== 200) throw new Error(`oauth ${response.status}`);
  const answer = await response.json();
  cache.token = answer.access_token;
  cache.expires = now + Number(answer.expires_in ?? 3600);
  cache.email = account.client_email;
  return cache.token;
}

/** What Google's answer means, in APNs' words, so the Mac treats both alike (a token gone is dropped). */
export function fcmOutcome(status, error) {
  if (status === 200) return { apns: 200 };
  const code = error?.details?.find?.((d) => d?.errorCode)?.errorCode ?? error?.status;
  if (status === 404 || code === "UNREGISTERED") return { apns: 410, reason: "Unregistered" };
  if (status === 400 && (code === "INVALID_ARGUMENT" || code === "SENDER_ID_MISMATCH")) return { apns: 400, reason: "BadDeviceToken" };
  if (status === 401 || status === 403) return { apns: 403, reason: "InvalidProviderToken" };
  if (status === 429) return { apns: 429, reason: "TooManyRequests" };
  return { apns: status, reason: typeof code === "string" ? code.slice(0, 64) : undefined };
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
  if (push.service === "fcm") return handleFCM(push, env, deps);
  if (!apnsConfigured(env)) return json(501, { error: "push to iPhones is not set up on this relay" });

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

async function handleFCM(push, env, deps) {
  const account = fcmAccount(env);
  if (!account) return json(501, { error: "push to Android is not set up on this relay" });
  const tokenName = `push:${await sha256Hex(push.token)}`;
  if (!(await deps.limit(`push-room:${push.room}`, PUSH_LIMITS.room)) || !(await deps.limit(tokenName, PUSH_LIMITS.token))) {
    return json(429, { error: "slow down" });
  }
  const cache = deps.fcmCache ?? fcmSigned;
  let access;
  try {
    access = await fcmAccessToken(account, deps.now(), deps.fetch, cache);
  } catch {
    return json(502, { error: "google unreachable" });
  }
  let response;
  try {
    response = await deps.fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(account.project_id)}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${access}`, "content-type": "application/json" },
      body: JSON.stringify(fcmMessage(push)),
    });
  } catch {
    return json(502, { error: "fcm unreachable" });
  }
  let error;
  if (response.status !== 200) {
    try {
      error = (await response.json())?.error;
    } catch {
      error = undefined;
    }
    // A refused access token must not stay cached.
    if (response.status === 401 || response.status === 403) cache.token = null;
  }
  const outcome = fcmOutcome(response.status, error);
  return json(200, outcome.reason ? { apns: outcome.apns, reason: outcome.reason } : { apns: outcome.apns });
}
