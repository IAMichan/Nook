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

// As in workerd: a socket the relay closed stays listed while it closes, and sending on it throws.
class LingeringSocket extends FakeSocket {
  constructor() {
    super();
    this.readyState = 1;
  }
  send(message) {
    if (this.readyState !== 1) throw new TypeError("Can't call WebSocket send() after close()");
    super.send(message);
  }
  close(code) {
    super.close(code);
    this.readyState = 2;
  }
}

class LingeringRoom extends FakeRoom {
  getWebSockets(tag) {
    return this.entries.filter((e) => !tag || e.tags.includes(tag)).map((e) => e.ws);
  }
}

function lingering() {
  const room = new LingeringRoom();
  return { room, logic: new RoomLogic(room) };
}

test("a phone reaches the new Mac while the replaced one is still closing", () => {
  const { logic } = lingering();
  const old = new LingeringSocket();
  logic.accept(old, "mac");
  const mac = new LingeringSocket();
  logic.accept(mac, "mac");
  assert.equal(old.closedWith, REPLACED);

  const phone = new LingeringSocket();
  assert.equal(logic.accept(phone, "phone"), true);
  assert.equal(decode(mac.sent[0]).kind, OPEN);
  logic.message(phone, new Uint8Array([9]));
  assert.equal(decode(mac.sent[1]).kind, DATA);
});

test("the last open Mac closing takes the phones along, even with a replaced one still listed", () => {
  const { logic } = lingering();
  logic.accept(new LingeringSocket(), "mac");
  const mac = new LingeringSocket();
  logic.accept(mac, "mac");
  const phone = new LingeringSocket();
  logic.accept(phone, "phone");
  mac.close(1006);
  logic.closed(mac);
  assert.equal(phone.closedWith, MAC_OFFLINE);
});

test("phones that are still closing hold no place in the room", () => {
  const { logic } = lingering();
  logic.accept(new LingeringSocket(), "mac");
  for (let i = 0; i < MAX_PHONE_CONNECTIONS; i++) logic.accept(new LingeringSocket(), "phone");
  // A reconnected Mac closes them all; their peers are gone, so they linger.
  logic.accept(new LingeringSocket(), "mac");
  assert.equal(logic.accept(new LingeringSocket(), "phone"), true);
});

test("a send that fails never throws out of the room", () => {
  const { logic } = setup();
  const mac = new FakeSocket();
  logic.accept(mac, "mac");
  const phone = new FakeSocket();
  logic.accept(phone, "phone");
  const { connection } = decode(mac.sent[0]);
  const broken = () => {
    throw new TypeError("closing");
  };
  phone.send = broken;
  const data = new Uint8Array([DATA, 0, 0, 0, 0, 1]);
  new DataView(data.buffer).setUint32(1, connection);
  assert.doesNotThrow(() => logic.message(mac, data));

  mac.send = broken;
  assert.doesNotThrow(() => logic.message(phone, new Uint8Array([1])));
  assert.equal(phone.closedWith, MAC_OFFLINE);
  assert.doesNotThrow(() => logic.closed(phone));
  const late = new FakeSocket();
  assert.equal(logic.accept(late, "phone"), false);
  assert.equal(late.closedWith, MAC_OFFLINE);
});
