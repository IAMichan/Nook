import assert from "node:assert/strict";
import test from "node:test";
import { ANSWER_TIMEOUT_MS, MAX_WAITING, TunnelLogic, mayListenMCP, mcpRoomOf, packRequest, routeMCP, unpackAnswer } from "../worker/mcp.js";

class Sockets {
  constructor() {
    this.open = [];
  }
  getWebSockets() {
    return this.open;
  }
  acceptWebSocket(ws) {
    this.open.push(ws);
  }
}

const socket = () => ({ sent: [], closed: null, readyState: 1, send(m) { this.sent.push(m); }, close(code) { this.closed = code; } });
const post = (body = "{}", headers = {}) => new Request("https://relay.test/v1/mcp/x", { method: "POST", body, headers });
const b64 = (text) => btoa(text);

test("only the token's owner may listen, and the room does not give the token away", async () => {
  const token = "t".repeat(40);
  const room = await mcpRoomOf(token);
  assert.match(room, /^[0-9a-f]{32}$/);
  assert.ok(!room.includes(token));
  assert.equal(await mayListenMCP(token, room), true);
  assert.equal(await mayListenMCP("u".repeat(40), room), false);
  assert.equal(await mayListenMCP("short", await mcpRoomOf("short")), false);
  assert.equal(await mayListenMCP(undefined, room), false);
});

test("a room is a different room from the webhook one", async () => {
  const { roomOf } = await import("../worker/hooks.js");
  const token = "t".repeat(40);
  assert.notEqual(await mcpRoomOf(token), await roomOf(token));
});

test("routes: the endpoint, the sign-in and the discovery documents", () => {
  const room = "a".repeat(32);
  assert.deepEqual(routeMCP(`/v1/mcp/${room}`), { room, path: "/" });
  assert.deepEqual(routeMCP(`/v1/mcp/${room}/authorize`), { room, path: "/authorize" });
  assert.deepEqual(routeMCP(`/v1/mcp/${room}/listen`), { room, path: "/listen" });
  assert.deepEqual(routeMCP(`/.well-known/oauth-protected-resource/v1/mcp/${room}`), { room, path: "/.well-known/oauth-protected-resource" });
  assert.equal(routeMCP(`/.well-known/other/v1/mcp/${room}`), null);
  assert.equal(routeMCP("/v1/mcp/short"), null);
  assert.equal(routeMCP("/v1/rooms/" + room), null);
});

test("a request is packed with only the headers the Mac needs", async () => {
  const packed = await packRequest(post('{"a":1}', { authorization: "Bearer x", cookie: "secret", "x-forwarded-for": "1.2.3.4" }), "/", "id1");
  assert.equal(packed.id, "id1");
  assert.equal(packed.method, "POST");
  assert.deepEqual(Object.keys(packed.headers).sort(), ["authorization", "content-type"]);
  assert.equal(atob(packed.body), '{"a":1}');
});

test("an answer carries only the headers an assistant may get", async () => {
  const response = unpackAnswer({ status: 302, headers: { location: "https://a/cb", "set-cookie": "x=1", "content-type": "text/html" }, body: b64("hi") });
  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "https://a/cb");
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(unpackAnswer({ status: 999, body: "" }).status, 502);
  assert.equal(unpackAnswer({ status: 204, body: "" }).body, null);
});

test("a request goes to the Mac and its answer comes back", async () => {
  const sockets = new Sockets();
  const mac = socket();
  sockets.open.push(mac);
  const tunnel = new TunnelLogic(sockets, { newID: () => "r1" });
  const pending = tunnel.deliver(post("{}"), "/");
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(JSON.parse(mac.sent[0]).id, "r1");
  tunnel.message(JSON.stringify({ id: "r1", status: 200, headers: { "content-type": "application/json" }, body: b64('{"ok":true}') }));
  const response = await pending;
  assert.equal(response.status, 200);
  assert.equal(await response.text(), '{"ok":true}');
  assert.equal(tunnel.waiting.size, 0);
});

test("no Mac means 503, a silent Mac 504, and too many at once 429", async () => {
  const none = new TunnelLogic(new Sockets());
  assert.equal((await none.deliver(post(), "/")).status, 503);

  const sockets = new Sockets();
  sockets.open.push(socket());
  const slow = new TunnelLogic(sockets, { timeoutMs: 5 });
  assert.equal((await slow.deliver(post(), "/")).status, 504);
  assert.equal(slow.waiting.size, 0);

  const busy = new TunnelLogic(sockets, { timeoutMs: 1000 });
  let id = 0;
  busy.newID = () => "n" + id++;
  const held = [];
  for (let n = 0; n < MAX_WAITING; n++) held.push(busy.deliver(post(), "/"));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal((await busy.deliver(post(), "/")).status, 429);
  for (let n = 0; n < MAX_WAITING; n++) busy.message(JSON.stringify({ id: "n" + n, status: 200, body: "" }));
  await Promise.all(held);
  assert.ok(ANSWER_TIMEOUT_MS < 300_000);
});

test("a newer Mac connection replaces the old one, and nonsense from it is ignored", () => {
  const sockets = new Sockets();
  const old = socket();
  sockets.open.push(old);
  const tunnel = new TunnelLogic(sockets);
  tunnel.listen(socket());
  assert.equal(old.closed, 4000);
  tunnel.message("not json");
  tunnel.message(JSON.stringify({ status: 200 }));
  tunnel.message(new ArrayBuffer(1));
});

test("a body that is too large is refused", async () => {
  const sockets = new Sockets();
  sockets.open.push(socket());
  const tunnel = new TunnelLogic(sockets);
  const response = await tunnel.deliver(post("x".repeat(1024 * 1024 + 10)), "/");
  assert.equal(response.status, 413);
});
