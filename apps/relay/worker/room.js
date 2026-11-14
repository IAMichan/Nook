import { CLOSE, DATA, OPEN, decode, encode } from "./mux.js";

/** Most phone connections one room holds at once (a live connection and a few short ones). */
export const MAX_PHONE_CONNECTIONS = 8;
/** The largest message passed on: a companion frame is at most 256 KB, sealed and framed. */
export const MAX_MESSAGE = 512 * 1024;

// Close codes a phone sees.
export const MAC_OFFLINE = 4404;
export const ROOM_FULL = 4429;
export const REPLACED = 4000;

/**
 * One paired phone's room: at most one Mac socket and a few phone sockets, with bytes passed between them. It reads
 * nothing: everything that passes is sealed with the pairing key the relay never sees.
 *
 * `sockets` is the Durable Object's WebSocket set (`ctx.getWebSockets(tag)`), so the room survives hibernation:
 * every socket carries its role and connection number as tags and in its attachment.
 */
export class RoomLogic {
  /** @param {{ getWebSockets(tag?: string): any[], acceptWebSocket(ws: any, tags: string[]): void }} sockets */
  constructor(sockets) {
    this.sockets = sockets;
  }

  /** The Mac's open socket. A replaced one stays listed while it closes, which can take long when its peer is gone. */
  mac() {
    return this.sockets.getWebSockets("mac").find(isOpen) ?? null;
  }

  /** Takes in a new socket; false when it was closed right away (no Mac, room full). */
  accept(ws, role) {
    if (role === "mac") {
      for (const old of this.sockets.getWebSockets("mac")) safeClose(old, REPLACED, "replaced");
      // Phones that talked to the previous Mac socket talk to nobody now.
      for (const phone of this.sockets.getWebSockets("phone")) safeClose(phone, MAC_OFFLINE, "mac reconnected");
      this.sockets.acceptWebSocket(ws, ["mac"]);
      ws.serializeAttachment({ role: "mac" });
      return true;
    }
    const mac = this.mac();
    this.sockets.acceptWebSocket(ws, ["phone"]);
    if (!mac) {
      safeClose(ws, MAC_OFFLINE, "mac offline");
      return false;
    }
    // Phones closed earlier (a reconnected Mac, a full room) can stay listed while they close; they hold no place.
    if (this.sockets.getWebSockets("phone").filter(isOpen).length > MAX_PHONE_CONNECTIONS) {
      safeClose(ws, ROOM_FULL, "room full");
      return false;
    }
    const taken = new Set(this.sockets.getWebSockets("phone").map((s) => s.deserializeAttachment()?.connection));
    let connection;
    do connection = (Math.random() * 0xffffffff) >>> 0;
    while (taken.has(connection));
    ws.serializeAttachment({ role: "phone", connection });
    if (!safeSend(mac, encode(OPEN, connection))) {
      safeClose(ws, MAC_OFFLINE, "mac offline");
      return false;
    }
    return true;
  }

  message(ws, message) {
    // Text is only the keep-alive ("ping"), answered by the runtime without waking the room.
    if (typeof message === "string") return;
    const bytes = message instanceof Uint8Array ? message : new Uint8Array(message);
    if (bytes.byteLength > MAX_MESSAGE) return safeClose(ws, 1009, "too large");
    const attachment = ws.deserializeAttachment();
    if (attachment?.role === "phone") {
      const mac = this.mac();
      if (!mac || !safeSend(mac, encode(DATA, attachment.connection, bytes))) safeClose(ws, MAC_OFFLINE, "mac offline");
      return;
    }
    const decoded = decode(bytes);
    if (!decoded) return;
    const phone = this.phone(decoded.connection);
    if (!phone) {
      // That phone left already; tell the Mac so it lets go too.
      if (decoded.kind === DATA) safeSend(ws, encode(CLOSE, decoded.connection));
      return;
    }
    if (decoded.kind === DATA) safeSend(phone, decoded.payload);
    else if (decoded.kind === CLOSE) safeClose(phone, 1000, "closed");
  }

  closed(ws) {
    const attachment = ws.deserializeAttachment();
    if (attachment?.role === "phone") {
      const mac = this.mac();
      if (mac) safeSend(mac, encode(CLOSE, attachment.connection));
    } else if (attachment?.role === "mac" && !this.sockets.getWebSockets("mac").some((s) => s !== ws && isOpen(s))) {
      for (const phone of this.sockets.getWebSockets("phone")) safeClose(phone, MAC_OFFLINE, "mac offline");
    }
  }

  phone(connection) {
    return this.sockets.getWebSockets("phone").find((s) => s.deserializeAttachment()?.connection === connection) ?? null;
  }
}

/** Open, or a socket that does not say (as in the tests). */
export function isOpen(ws) {
  return ws.readyState === undefined || ws.readyState === 1;
}

/** Sends, and says whether it could: a socket that is closing throws. */
export function safeSend(ws, message) {
  try {
    ws.send(message);
    return true;
  } catch {
    return false;
  }
}

export function safeClose(ws, code, reason) {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}
