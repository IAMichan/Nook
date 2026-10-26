import assert from "node:assert/strict";
import test from "node:test";
import {
  GENERIC_ALERT,
  MAX_BODY,
  PUSH_LIMITS,
  admit,
  apnsJWT,
  apnsPayload,
  handlePush,
  parsePushRequest,
  pushConfigured,
  sha256Hex,
} from "../worker/push.js";

const room = "cae98fe2b67a6f65273aa18446bdf884";
const token = "a1".repeat(32);
const sealed = { d: "0123456789abcdef", s: "A".repeat(120) };

async function makeEnv() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${der.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----`;
  return { env: { APNS_KEY: pem, APNS_KEY_ID: "ABCDE12345", APNS_TEAM_ID: "TEAM123456" }, publicKey: pair.publicKey };
}

function request(body, { method = "POST" } = {}) {
  const text = typeof body === "string" ? body : JSON.stringify(body);
  return new Request("https://relay.example/v1/push", { method, body: method === "POST" ? text : undefined });
}

function deps({ status = 200, reason, limit = async () => true, fail = false } = {}) {
  const sent = [];
  return {
    sent,
    cache: {},
    now: () => 1_760_000_000,
    limit,
    fetch: async (url, init) => {
      if (fail) throw new Error("offline");
      sent.push({ url, init });
      return new Response(reason ? JSON.stringify({ reason }) : null, { status });
    },
  };
}

function fromBase64url(text) {
  return Buffer.from(text.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

test("checks every field and refuses the rest", () => {
  const ok = parsePushRequest({ room, token: token.toUpperCase(), production: true, sealed, collapse: "ab12", urgent: true });
  assert.equal(ok.value.token, token, "lowercased for the URL");
  assert.equal(ok.value.urgent, true);
  assert.equal(parsePushRequest({ room, token, production: false, sealed }).value.urgent, false);

  const bad = [
    null,
    [],
    { room: "../x", token, production: true, sealed },
    { room, token: "zz".repeat(32), production: true, sealed },
    { room, token: "ab", production: true, sealed },
    { room, token: `${token}/../x`, production: true, sealed },
    { room, token, production: "yes", sealed },
    { room, token, production: true },
    { room, token, production: true, sealed: { d: "not hex", s: sealed.s } },
    { room, token, production: true, sealed: { d: sealed.d, s: "short" } },
    { room, token, production: true, sealed: { d: sealed.d, s: "A".repeat(3001) } },
    { room, token, production: true, sealed: { d: sealed.d, s: "<script>".repeat(10) } },
    { room, token, production: true, sealed, collapse: "approval:session:item" },
    { room, token, production: true, sealed, urgent: 1 },
  ];
  for (const body of bad) assert.ok(parsePushRequest(body).error, JSON.stringify(body));
});

test("the alert Apple sees is generic, mutable and carries the blob untouched", () => {
  const payload = apnsPayload({ sealed, urgent: false });
  assert.deepEqual(payload.aps.alert, GENERIC_ALERT);
  assert.equal(payload.aps["mutable-content"], 1);
  assert.equal(payload.aps["interruption-level"], "active");
  assert.deepEqual(payload["nook-sealed"], sealed);
  assert.equal(apnsPayload({ sealed, urgent: true }).aps["interruption-level"], "time-sensitive");
  assert.ok(!JSON.stringify(payload).includes(room), "no room in what Apple gets");
});

test("limits per minute and per hour", () => {
  const limits = { perMinute: 2, perHour: 3 };
  let state;
  const at = (now) => {
    const result = admit(state, now, limits);
    state = result.state;
    return result.allowed;
  };
  assert.deepEqual([at(0), at(1), at(2)], [true, true, false], "two a minute");
  assert.deepEqual([at(60), at(61)], [true, false], "the hour's third, then the hour is full");
  assert.equal(at(3600), true, "a new hour");
  assert.ok(PUSH_LIMITS.room.perMinute > 0 && PUSH_LIMITS.token.perHour >= PUSH_LIMITS.room.perHour);
});

test("signs an ES256 token Apple can check, and reuses it", async () => {
  const { env, publicKey } = await makeEnv();
  const cache = {};
  const jwt = await apnsJWT(env, 1000, cache);
  const [header, claims, signature] = jwt.split(".");
  assert.deepEqual(JSON.parse(fromBase64url(header)), { alg: "ES256", kid: "ABCDE12345" });
  assert.deepEqual(JSON.parse(fromBase64url(claims)), { iss: "TEAM123456", iat: 1000 });
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, fromBase64url(signature),
    new TextEncoder().encode(`${header}.${claims}`));
  assert.ok(valid);
  assert.equal(await apnsJWT(env, 1000 + 49 * 60, cache), jwt, "reused within 50 minutes");
  assert.notEqual(await apnsJWT(env, 1000 + 51 * 60, cache), jwt, "a new one after");
});

test("is off without Nook's APNs key", async () => {
  assert.equal(pushConfigured({}), false);
  const response = await handlePush(request({ room, token, production: true, sealed }), {}, deps());
  assert.equal(response.status, 501);
});

test("forwards a valid push to the right APNs host with the right headers", async () => {
  const { env } = await makeEnv();
  const d = deps();
  const response = await handlePush(request({ room, token, production: false, sealed, collapse: "ab12", urgent: true }), env, d);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { apns: 200 });
  assert.equal(d.sent.length, 1);
  const { url, init } = d.sent[0];
  assert.equal(url, `https://api.sandbox.push.apple.com/3/device/${token}`);
  assert.equal(init.headers["apns-topic"], "nl.imdigital.nook.companion");
  assert.equal(init.headers["apns-push-type"], "alert");
  assert.equal(init.headers["apns-priority"], "10");
  assert.equal(init.headers["apns-collapse-id"], "ab12");
  assert.match(init.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.deepEqual(JSON.parse(init.body)["nook-sealed"], sealed);

  const production = deps();
  await handlePush(request({ room, token, production: true, sealed }), { ...env, APNS_TOPIC: "com.example.app" }, production);
  assert.equal(production.sent[0].url, `https://api.push.apple.com/3/device/${token}`);
  assert.equal(production.sent[0].init.headers["apns-topic"], "com.example.app");
  assert.equal(production.sent[0].init.headers["apns-priority"], "5");
  assert.equal(production.sent[0].init.headers["apns-collapse-id"], undefined);
});

test("passes Apple's answer back so the Mac can drop a dead token", async () => {
  const { env } = await makeEnv();
  const response = await handlePush(request({ room, token, production: true, sealed }), env, deps({ status: 410, reason: "Unregistered" }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { apns: 410, reason: "Unregistered" });

  const offline = await handlePush(request({ room, token, production: true, sealed }), env, deps({ fail: true }));
  assert.equal(offline.status, 502);
});

test("rate limits per room and per token, naming the token only by its hash", async () => {
  const { env } = await makeEnv();
  const names = [];
  const limited = deps({
    limit: async (name) => {
      names.push(name);
      return !name.startsWith("push:");
    },
  });
  const response = await handlePush(request({ room, token, production: true, sealed }), env, limited);
  assert.equal(response.status, 429);
  assert.equal(limited.sent.length, 0, "nothing reaches Apple");
  assert.deepEqual(names, [`push-room:${room}`, `push:${await sha256Hex(token)}`]);
  assert.ok(!names.some((name) => name.includes(token)));
});

test("refuses what is not a push", async () => {
  const { env } = await makeEnv();
  assert.equal((await handlePush(request("not json"), env, deps())).status, 400);
  assert.equal((await handlePush(request({ room }), env, deps())).status, 400);
  assert.equal((await handlePush(request("x".repeat(MAX_BODY + 1)), env, deps())).status, 413);
  assert.equal((await handlePush(request(null, { method: "GET" }), env, deps())).status, 405);
});
