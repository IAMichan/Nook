import assert from "node:assert/strict";
import test from "node:test";
import { CLOSE, DATA, OPEN, decode } from "../worker/mux.js";
import { MAC_OFFLINE, MAX_PHONE_CONNECTIONS, REPLACED, ROOM_FULL, RoomLogic } from "../worker/room.js";

class FakeSocket {
  constructor() {
    this.sent = [];
    this.closedWith = null;
    this.attachment = null;
  }
  send(message) {
    this.sent.push(message);
  }
  close(code) {
    this.closedWith = code;
  }
  serializeAttachment(value) {
    this.attachment = value;
  }
  deserializeAttachment() {
    return this.attachment;
  }
}

class FakeRoom {
  constructor() {
    this.entries = [];
  }
  acceptWebSocket(ws, tags) {
    this.entries.push({ ws, tags });
  }
  getWebSockets(tag) {
    return this.entries.filter((e) => e.ws.closedWith === null && (!tag || e.tags.includes(tag))).map((e) => e.ws);
  }
}

function setup() {
  const room = new FakeRoom();
  return { room, logic: new RoomLogic(room) };
}

test("a phone without a Mac is told so at once", () => {
  const { logic } = setup();
  const phone = new FakeSocket();
  assert.equal(logic.accept(phone, "phone"), false);
  assert.equal(phone.closedWith, MAC_OFFLINE);
});

test("bytes pass both ways, each phone connection by its number", () => {
  const { logic } = setup();
  const mac = new FakeSocket();
  logic.accept(mac, "mac");
  const phone = new FakeSocket();
  assert.equal(logic.accept(phone, "phone"), true);
  const opened = decode(mac.sent[0]);
  assert.equal(opened.kind, OPEN);

  logic.message(phone, new Uint8Array([1, 2, 3]));
  const forwarded = decode(mac.sent[1]);
  assert.equal(forwarded.kind, DATA);
  assert.equal(forwarded.connection, opened.connection);
  assert.deepEqual([...forwarded.payload], [1, 2, 3]);

  const answer = new Uint8Array([2, 0, 0, 0, 0, 7]);
  new DataView(answer.buffer).setUint32(1, opened.connection);
  logic.message(mac, answer);
  assert.deepEqual([...phone.sent[0]], [7]);

  logic.message(phone, "ping");
  assert.equal(mac.sent.length, 2, "keep-alives are not passed on");
});

test("closing either side closes the other", () => {
  const { logic } = setup();
  const mac = new FakeSocket();
  logic.accept(mac, "mac");
  const phone = new FakeSocket();
  logic.accept(phone, "phone");
  const { connection } = decode(mac.sent[0]);

  phone.close(1000);
  logic.closed(phone);
  const closed = decode(mac.sent.at(-1));
  assert.equal(closed.kind, CLOSE);
  assert.equal(closed.connection, connection);

  const other = new FakeSocket();
  logic.accept(other, "phone");
  const second = decode(mac.sent.at(-1)).connection;
  const close = new Uint8Array(5);
  close[0] = CLOSE;
  new DataView(close.buffer).setUint32(1, second);
  logic.message(mac, close);
  assert.equal(other.closedWith, 1000);
});

test("a Mac that goes away takes its phones along, and a new Mac replaces the old", () => {
  const { logic } = setup();
  const mac = new FakeSocket();
  logic.accept(mac, "mac");
  const phone = new FakeSocket();
  logic.accept(phone, "phone");
  const newer = new FakeSocket();
  logic.accept(newer, "mac");
  assert.equal(mac.closedWith, REPLACED);
  assert.equal(phone.closedWith, MAC_OFFLINE);

  const late = new FakeSocket();
  logic.accept(late, "phone");
  newer.close(1006);
  logic.closed(newer);
  assert.equal(late.closedWith, MAC_OFFLINE);
});

test("a room holds a few phone connections", () => {
  const { logic } = setup();
  logic.accept(new FakeSocket(), "mac");
  for (let i = 0; i < MAX_PHONE_CONNECTIONS; i++) assert.equal(logic.accept(new FakeSocket(), "phone"), true);
  const extra = new FakeSocket();
  assert.equal(logic.accept(extra, "phone"), false);
  assert.equal(extra.closedWith, ROOM_FULL);
});

test("data for a phone that left makes the Mac let go", () => {
  const { logic } = setup();
  const mac = new FakeSocket();
  logic.accept(mac, "mac");
  const message = new Uint8Array([DATA, 0, 0, 0, 42, 1]);
  logic.message(mac, message);
  const reply = decode(mac.sent.at(-1));
  assert.equal(reply.kind, CLOSE);
  assert.equal(reply.connection, 42);
});
