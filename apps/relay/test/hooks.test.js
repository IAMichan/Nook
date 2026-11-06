import assert from "node:assert/strict";
import test from "node:test";
import { HookLogic, MAX_BODY, MAX_WAITING, isHook, mayListen, roomOf } from "../worker/hooks.js";

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

const socket = () => ({ sent: [], closed: null, send(m) { this.sent.push(m); }, close(code) { this.closed = code; } });
const request = (body = new Uint8Array([1, 2]), headers = {}) => ({
  hook: "00000000-0000-0000-0000-000000000000",
  headers: new Headers(headers),
  body: body.buffer,
});

test("only the token's owner may listen", async () => {
  const token = "x".repeat(40);
  const room = await roomOf(token);
  assert.match(room, /^[0-9a-f]{32}$/);
  assert.equal(await mayListen(token, room), true);
  assert.equal(await mayListen("y".repeat(40), room), false);
  assert.equal(await mayListen("short", await roomOf("short")), false);
  assert.equal(await mayListen(undefined, room), false);
});

test("hooks are task ids", () => {
  assert.equal(isHook("00000000-0000-0000-0000-000000000000"), true);
  assert.equal(isHook("../x"), false);
});

test("a request goes to the Mac and its answer to the sender", async () => {
  const sockets = new Sockets();
  const mac = socket();
  const logic = new HookLogic(sockets, { newID: () => "a" });
  logic.listen(mac);
  const answer = logic.deliver(request(new Uint8Array([104, 105]), { "X-Hub-Signature-256": "sha256=1", Cookie: "no" }));
  const sent = JSON.parse(mac.sent[0]);
  assert.equal(sent.path, "/hooks/00000000-0000-0000-0000-000000000000");
  assert.equal(sent.body, "aGk=");
  assert.deepEqual(sent.headers, { "x-hub-signature-256": "sha256=1" });
  logic.message(JSON.stringify({ id: "a", status: 202, message: "accepted" }));
  assert.deepEqual(await answer, { status: 202, message: "accepted" });
});

test("without a Mac the sender hears so", async () => {
  assert.equal((await new HookLogic(new Sockets()).deliver(request())).status, 503);
});

test("a Mac that stays silent times out", async () => {
  const sockets = new Sockets();
  const logic = new HookLogic(sockets, { timeoutMs: 1 });
  logic.listen(socket());
  assert.equal((await logic.deliver(request())).status, 504);
  assert.equal(logic.waiting.size, 0);
});

test("limits hold", async () => {
  const sockets = new Sockets();
  let id = 0;
  const logic = new HookLogic(sockets, { timeoutMs: 5, newID: () => String(id++) });
  logic.listen(socket());
  assert.equal((await logic.deliver(request(new Uint8Array(MAX_BODY + 1)))).status, 413);
  const waiting = Array.from({ length: MAX_WAITING }, () => logic.deliver(request()));
  assert.equal((await logic.deliver(request())).status, 429);
  await Promise.all(waiting);
});

test("a closing socket is passed over", async () => {
  const sockets = new Sockets();
  const logic = new HookLogic(sockets, { newID: () => "a" });
  const closing = Object.assign(socket(), { readyState: 2 });
  const open = Object.assign(socket(), { readyState: 1 });
  sockets.open.push(closing, open);
  const answer = logic.deliver(request());
  assert.equal(closing.sent.length, 0);
  assert.equal(open.sent.length, 1);
  logic.message(JSON.stringify({ id: "a", status: 202, message: "ok" }));
  assert.equal((await answer).status, 202);
});

test("a new socket replaces the old one; bad answers are ignored", () => {
  const sockets = new Sockets();
  const logic = new HookLogic(sockets);
  const first = socket();
  logic.listen(first);
  logic.listen(socket());
  assert.equal(first.closed, 4000);
  logic.message("not json");
  logic.message(JSON.stringify({ id: "nobody", status: 200 }));
});
