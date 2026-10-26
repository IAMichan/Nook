// How the relay and the Mac share the Mac's one WebSocket among a phone's connections. Every message on the Mac's
// socket is [kind: 1 byte][connection: 4 bytes, big-endian][payload]. A phone's own socket carries the payload alone.
// The Mac speaks the same (packages/protocol/Sources/CompanionRelay.swift, RelayMux).

export const OPEN = 1;
export const DATA = 2;
export const CLOSE = 3;

/** @param {number} kind @param {number} connection @param {Uint8Array} [payload] */
export function encode(kind, connection, payload = new Uint8Array(0)) {
  const out = new Uint8Array(5 + payload.byteLength);
  out[0] = kind;
  new DataView(out.buffer).setUint32(1, connection >>> 0);
  out.set(payload, 5);
  return out;
}

/** @param {ArrayBuffer | Uint8Array} message */
export function decode(message) {
  const bytes = message instanceof Uint8Array ? message : new Uint8Array(message);
  if (bytes.byteLength < 5 || ![OPEN, DATA, CLOSE].includes(bytes[0])) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { kind: bytes[0], connection: view.getUint32(1), payload: bytes.subarray(5) };
}

/** A room name: 32 lowercase hex characters, derived on the Mac and the phone from their pairing key. */
export function isRoom(text) {
  return typeof text === "string" && /^[0-9a-f]{32}$/.test(text);
}
