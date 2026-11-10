// A guest link's page (docs/WORKSPACE-AGENTS.md, "Guest links"). Everything between the page and the Mac is sealed with
// AES-256-GCM under a key that only lives in the link's fragment, which a browser never sends, so this Worker passes bytes it
// cannot read or forge. The page talks to the Mac through an ordinary room (room.js), as a phone does. The Mac speaks the same
// (GuestLinkSeal.swift, GuestLinkRoom.swift, GuestLink.swift); the test vectors in test/guest.test.js are shared with
// GuestLinkTests.

export const GUEST_LABEL = "nook-guest-room-v1";
/** As GuestLink.sliceCharacters: a message travels as JSON text in slices that fit a relay frame. */
export const SLICE_CHARACTERS = 256 * 1024;
export const MAX_FILES = 4;
export const MAX_MESSAGE_BYTES = 10 * 1024 * 1024;

/** The room of a key: the first 32 hex of HMAC-SHA256(key, label). */
export async function guestRoom(rawKey) {
  const key = await crypto.subtle.importKey("raw", rawKey, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(GUEST_LABEL)));
  return [...signed].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

/** Opens `nonce (12 bytes) + ciphertext + tag` into text. */
export async function openSealed(rawKey, sealed) {
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: sealed.slice(0, 12) }, key, sealed.slice(12));
  return new TextDecoder().decode(plain);
}

/** Seals text as the page does. */
export async function seal(rawKey, text, iv = crypto.getRandomValues(new Uint8Array(12))) {
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["encrypt"]);
  const data = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(text)));
  const out = new Uint8Array(12 + data.length);
  out.set(iv);
  out.set(data, 12);
  return out;
}

/** A message's JSON text in slices, as the page sends it: `{"t":"slice","id","i","n","d"}` each. */
export function slices(id, json, size = SLICE_CHARACTERS) {
  const count = Math.max(1, Math.ceil(json.length / size));
  const out = [];
  for (let i = 0; i < count; i++) out.push(JSON.stringify({ t: "slice", id, i, n: count, d: json.slice(i * size, (i + 1) * size) }));
  return out;
}

/** The page, allowed to open a WebSocket to this relay only. */
export function guestResponse(request) {
  const url = new URL(request?.url ?? "https://relay.invalid/v1/guest");
  const socket = (url.protocol === "http:" ? "ws://" : "wss://") + url.host;
  return new Response(GUEST_PAGE, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
      "content-security-policy":
        `default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src ${socket}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
    },
  });
}

// The page: no framework, no outside resources, never innerHTML. The functions above are repeated inside it (it is served as
// one file); test/guest.test.js checks they agree.
export const GUEST_PAGE = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Nook session</title>
<style>
:root{color-scheme:dark}body{margin:0;background:#141414;color:#eee;font:15px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:720px;margin:0 auto;padding:20px 16px 170px}h1{font-size:17px;margin:0}#state{color:#999;font-size:13px;margin:4px 0 18px}
.e{white-space:pre-wrap;overflow-wrap:anywhere;margin:0 0 12px}.you,.held{background:#262626;border-radius:10px;padding:8px 12px}
.held{border:1px dashed #666;color:#bbb}.held small{display:block;color:#d9a441;font-size:12px}.tool{color:#999;font:12px ui-monospace,monospace}
form{position:fixed;left:0;right:0;bottom:0;background:#141414;border-top:1px solid #333;padding:10px 16px}
.r{display:flex;gap:8px;max-width:720px;margin:0 auto}textarea{flex:1;background:#262626;color:#eee;border:0;border-radius:8px;padding:8px;font:inherit;resize:none}
button,label.b{background:#eee;color:#141414;border:0;border-radius:8px;padding:0 14px;font:inherit;cursor:pointer;display:flex;align-items:center}
label.b{background:#333;color:#eee}#files{max-width:720px;margin:6px auto 0;color:#999;font-size:12px;min-height:16px}
#note{max-width:720px;margin:4px auto 0;color:#999;font-size:12px}
</style></head><body><main><h1 id="title">Nook session</h1><div id="state">Connecting…</div><div id="list"></div></main>
<form id="f"><div class="r"><textarea id="m" rows="2" maxlength="4000" placeholder="Write a message. It waits until the owner sends it."></textarea>
<label class="b" title="Attach up to 4 files, 10 MB together">+<input id="pick" type="file" multiple hidden></label><button>Send</button></div>
<div id="files"></div><div id="note">Messages and files wait for the owner of this session, who decides whether the agent gets them.</div></form>
<script>
(async () => {
  const LABEL = "${GUEST_LABEL}", SLICE = ${SLICE_CHARACTERS}, MAX_FILES = ${MAX_FILES}, MAX_BYTES = ${MAX_MESSAGE_BYTES};
  const IMAGES = ["image/png", "image/jpeg", "image/gif", "image/webp"];
  const $ = (id) => document.getElementById(id);
  const state = $("state"), list = $("list"), filesLine = $("files");
  const say = (t) => { state.textContent = t; };
  const fragment = location.hash.slice(1);
  history.replaceState(null, "", location.pathname);
  let raw;
  try { raw = Uint8Array.from(atob(fragment.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)); } catch { raw = new Uint8Array(); }
  if (raw.length !== 32) return say("This link is not complete.");
  const mac = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signed = new Uint8Array(await crypto.subtle.sign("HMAC", mac, new TextEncoder().encode(LABEL)));
  const room = [...signed].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
  const seal = async (text) => {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const data = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(text)));
    const out = new Uint8Array(12 + data.length); out.set(iv); out.set(data, 12); return out;
  };
  let socket, ended = false, attached = [], until = 0;
  const reasons = { tooLong: "The message is too long.", tooManyFiles: "At most 4 files.", tooLarge: "Files can be 10 MB together.",
    fileType: "Pictures must be PNG, JPEG, GIF or WebP.", holdFull: "Too much waits for the owner already. Try again later.",
    empty: "Write something or attach a file.", malformed: "The message did not arrive.", expired: "This link no longer works." };
  const showFiles = () => { filesLine.textContent = attached.map((f) => f.name).join(", "); };
  const draw = (view) => {
    until = view.until || 0;
    $("title").textContent = view.title || "Nook session";
    const time = until ? new Date(until * 1000).toLocaleString() : "";
    say((view.working ? "The agent is working" : "The agent is waiting") + (time ? " · link works until " + time : ""));
    const rows = (view.entries || []).map((e) => {
      const d = document.createElement("div");
      d.className = "e " + (["you", "agent", "tool"].includes(e.kind) ? e.kind : "agent");
      d.textContent = e.text;
      return d;
    });
    for (const h of view.held || []) {
      const d = document.createElement("div"); d.className = "e held";
      const s = document.createElement("small"); s.textContent = "Waiting for the owner";
      d.append(s, document.createTextNode(h.text + (h.files.length ? "\\n" + h.files.join(", ") : "")));
      rows.push(d);
    }
    const end = innerHeight + scrollY >= document.body.scrollHeight - 40;
    list.replaceChildren(...rows);
    if (end) scrollTo(0, document.body.scrollHeight);
  };
  const connect = () => {
    socket = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/v1/rooms/" + room + "?role=phone");
    socket.binaryType = "arraybuffer";
    socket.onmessage = async (event) => {
      if (typeof event.data === "string") return;
      const sealed = new Uint8Array(event.data);
      let message;
      try {
        const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: sealed.slice(0, 12) }, key, sealed.slice(12));
        message = JSON.parse(new TextDecoder().decode(plain));
      } catch { return say("This link no longer works."); }
      if (message.t === "ended") { ended = true; say("The owner stopped sharing."); socket.onclose = null; socket.close(); $("f").hidden = true; return; }
      if (message.t === "ack") { $("note").textContent = message.ok ? "Sent. It waits for the owner." : (reasons[message.reason] || "The message did not arrive."); return; }
      if (message.t === "view") draw(message);
    };
    socket.onclose = (event) => {
      if (ended) return;
      say(event.code === 4404 ? "The owner's Mac is not reachable. Trying again…" : "Connection lost. Trying again…");
      setTimeout(connect, 5000);
    };
  };
  connect();
  const add = (files) => {
    for (const file of files) {
      if (attached.length >= MAX_FILES) { $("note").textContent = reasons.tooManyFiles; break; }
      if (file.type.startsWith("image/") && !IMAGES.includes(file.type)) { $("note").textContent = reasons.fileType; continue; }
      attached.push(file);
    }
    if (attached.reduce((n, f) => n + f.size, 0) > MAX_BYTES) { attached = []; $("note").textContent = reasons.tooLarge; }
    showFiles();
  };
  $("pick").addEventListener("change", (e) => { add([...e.target.files]); e.target.value = ""; });
  $("m").addEventListener("paste", (e) => { const f = [...(e.clipboardData?.files || [])]; if (f.length) { e.preventDefault(); add(f); } });
  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("drop", (e) => { e.preventDefault(); add([...(e.dataTransfer?.files || [])]); });
  const base64 = async (file) => {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let text = "";
    for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(text);
  };
  $("f").addEventListener("submit", async (event) => {
    event.preventDefault();
    const box = $("m"), text = box.value.trim();
    if ((!text && !attached.length) || !socket || socket.readyState !== 1) return;
    const files = [];
    for (const f of attached) files.push({ name: f.name, type: f.type, data: await base64(f) });
    const json = JSON.stringify({ text, files });
    const id = crypto.randomUUID();
    const count = Math.max(1, Math.ceil(json.length / SLICE));
    $("note").textContent = "Sending…";
    for (let i = 0; i < count; i++) {
      socket.send(await seal(JSON.stringify({ t: "slice", id, i, n: count, d: json.slice(i * SLICE, (i + 1) * SLICE) })));
    }
    box.value = ""; attached = []; showFiles();
  });
})();
</script></body></html>`;
