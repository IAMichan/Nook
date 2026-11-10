import assert from "node:assert/strict";
import test from "node:test";
import { GUEST_PAGE, guestResponse, guestRoom, openSealed, seal, slices, SLICE_CHARACTERS } from "../worker/guest.js";

const key = new Uint8Array(32).fill(7);
// The same values as GuestLinkTests (apps/macos/Tests/NookTests/GuestLinkTests.swift).
const ROOM = "afda7e68ed10b7e277b7f88de9de7a9d";
const SEALED = "AQEBAQEBAQEBAQEBDcP9laqdmme0o/4NUkMZRcSeNs46VJIxJRUxGm9nvmJGEeShmTgKqpY=";

test("the room matches the Mac", async () => {
  assert.equal(await guestRoom(key), ROOM);
});

test("what the Mac seals opens here, and the other way round", async () => {
  const sealed = Uint8Array.from(Buffer.from(SEALED, "base64"));
  assert.equal(await openSealed(key, sealed), '{"t":"view","title":"é"}');
  const mine = await seal(key, '{"t":"view","title":"é"}', new Uint8Array(12).fill(1));
  assert.equal(Buffer.from(mine).toString("base64"), SEALED);
  const other = new Uint8Array(32).fill(8);
  await assert.rejects(openSealed(other, sealed));
});

test("a message in slices fits a relay frame once sealed", async () => {
  const json = JSON.stringify({ text: "hi", files: [{ name: "a.bin", type: "", data: "x".repeat(SLICE_CHARACTERS * 2 + 5) }] });
  const parts = slices("m", json);
  assert.equal(parts.length, 3);
  assert.equal(parts.map((p) => JSON.parse(p).d).join(""), json);
  for (const part of parts) assert.ok((await seal(key, part)).byteLength < 512 * 1024);
});

test("the page uses the same label and limits as the Mac", () => {
  assert.match(GUEST_PAGE, /LABEL = "nook-guest-room-v1"/);
  assert.match(GUEST_PAGE, new RegExp(`SLICE = ${SLICE_CHARACTERS}`));
  assert.match(GUEST_PAGE, /MAX_FILES = 4/);
});

test("the page keeps the key out of the address and writes no html from the session", () => {
  assert.match(GUEST_PAGE, /history\.replaceState/);
  assert.match(GUEST_PAGE, /textContent = e\.text/);
  assert.doesNotMatch(GUEST_PAGE, /innerHTML/);
  assert.doesNotMatch(GUEST_PAGE, /<script src/);
});

test("the page is locked down", () => {
  const response = guestResponse(new Request("https://relay.example/v1/guest"));
  assert.equal(response.headers.get("referrer-policy"), "no-referrer");
  assert.match(response.headers.get("content-security-policy"), /default-src 'none'/);
  assert.match(response.headers.get("content-security-policy"), /connect-src wss:\/\/relay\.example;/);
  assert.equal(response.headers.get("cache-control"), "no-store");
});
