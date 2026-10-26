// The shared golden fixtures of the companion protocol (packages/protocol/Fixtures), read here as on the Mac
// (CompanionFixturesTests) and in the Tauri app (core/src/companion/fixtures.rs). See the parity table in
// docs/COMPANION.md.
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import { decode, encode, isRoom } from "../worker/mux.js";
import { MAC_OFFLINE, REPLACED, ROOM_FULL } from "../worker/room.js";

const fixture = (name) => JSON.parse(readFileSync(new URL(`../../../packages/protocol/Fixtures/${name}`, import.meta.url), "utf8"));
const relay = fixture("relay.json");

test("mux frames match the fixtures", () => {
  for (const { kind, connection, payload, frame } of relay.mux) {
    assert.equal(Buffer.from(encode(kind, connection, Buffer.from(payload, "hex"))).toString("hex"), frame);
    const decoded = decode(Buffer.from(frame, "hex"));
    assert.equal(decoded.kind, kind);
    assert.equal(decoded.connection, connection);
    assert.equal(Buffer.from(decoded.payload).toString("hex"), payload);
  }
  for (const frame of relay.invalidMux) assert.equal(decode(Buffer.from(frame, "hex")), null, frame);
});

test("rooms are derived from the key as on the Mac and the phone", () => {
  for (const { key, room } of relay.rooms) {
    const derived = createHmac("sha256", Buffer.from(key, "base64url")).update("nook-companion-relay-room-v1").digest()
      .subarray(0, 16).toString("hex");
    assert.equal(derived, room);
    assert.ok(isRoom(room));
  }
});

test("close codes match the fixtures", () => {
  assert.deepEqual({ macOffline: MAC_OFFLINE, roomFull: ROOM_FULL, replaced: REPLACED }, relay.closeCodes);
});
