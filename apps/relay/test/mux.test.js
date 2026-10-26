import assert from "node:assert/strict";
import test from "node:test";
import { CLOSE, DATA, OPEN, decode, encode, isRoom } from "../src/mux.js";

test("encodes as the Mac does", () => {
  // The same bytes CompanionRelayTests.testMuxRoundTrip expects.
  assert.deepEqual([...encode(DATA, 0x01020304, new Uint8Array([9, 8]))], [2, 1, 2, 3, 4, 9, 8]);
  const decoded = decode(encode(OPEN, 0xffffffff));
  assert.equal(decoded.kind, OPEN);
  assert.equal(decoded.connection, 0xffffffff);
  assert.equal(decoded.payload.byteLength, 0);
});

test("refuses what is not a message", () => {
  assert.equal(decode(new Uint8Array([2, 0, 0])), null);
  assert.equal(decode(new Uint8Array([9, 0, 0, 0, 1])), null);
  assert.equal(decode(encode(CLOSE, 5)).kind, CLOSE);
});

test("rooms are 32 hex characters", () => {
  assert.ok(isRoom("cae98fe2b67a6f65273aa18446bdf884"));
  assert.ok(!isRoom("CAE98FE2B67A6F65273AA18446BDF884"));
  assert.ok(!isRoom("../../etc/passwd"));
  assert.ok(!isRoom(undefined));
});
