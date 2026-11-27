// `nook://session/<id>?title=…`: a link to one of the sessions Nook runs (`SessionLink` on the Mac). "Copy session
// link" in a session's menu makes one; pasting it on an agent's composer turns it into that session's chip (a
// `ContextRef` of kind `session`), the same as picking it after `@`. Opened from anywhere else, it opens the session
// (`services/deep_link.rs`). The id is a run's UUID; the title is only a label for the chip and never decides which
// session is meant. No interface code, so tests use it on its own.
import { mentionToken, type ContextRef } from "./context-refs";

const PREFIX = "nook://session/";
/** A label longer than this is cut: a title only names the chip. */
export const MAX_TITLE_LENGTH = 200;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface SessionLink {
  /** The session's id, lowercased, as the composer's `@` list uses it. */
  id: string;
  title: string;
}

/** One line, no control characters, at most `MAX_TITLE_LENGTH` characters. */
function clean(title: string): string {
  // eslint-disable-next-line no-control-regex
  return [...title.replace(/[\u0000-\u001f\u007f]/g, "").trim()].slice(0, MAX_TITLE_LENGTH).join("");
}

/** Null for an id that is not a UUID: a link only ever names a session, never a path or a command. */
export function buildSessionLink(id: string, title: string): string | null {
  if (!UUID.test(id)) return null;
  const label = clean(title);
  return PREFIX + id.toLowerCase() + (label ? "?title=" + encodeURIComponent(label) : "");
}

export function parseSessionLink(text: string): SessionLink | null {
  const raw = text.trim();
  if (!raw.toLowerCase().startsWith(PREFIX)) return null;
  const rest = raw.slice(PREFIX.length);
  const [path, query = ""] = rest.split("?", 2);
  const segments = path.split("/").filter(Boolean);
  if (segments.length !== 1 || !UUID.test(segments[0])) return null;
  const id = segments[0].toLowerCase();
  let title = "";
  for (const pair of query.split("&")) {
    const [k, v = ""] = pair.split("=", 2);
    if (k === "title") {
      try {
        title = decodeURIComponent(v.replace(/\+/g, " "));
      } catch {
        title = v;
      }
    }
  }
  title = clean(title);
  return { id, title: title || id.slice(0, 8) };
}

export const sessionRef = (l: SessionLink): ContextRef => ({ kind: "session", id: l.id, label: l.title });

/** The session links in a text with where they are, in order: a paste may hold one among other words. */
export function findSessionLinks(text: string): { link: SessionLink; start: number; end: number }[] {
  const found: { link: SessionLink; start: number; end: number }[] = [];
  let cursor = 0;
  for (;;) {
    const start = text.indexOf(PREFIX, cursor);
    if (start < 0) break;
    let end = start;
    while (end < text.length && !/[\s)\]>]/.test(text[end])) end++;
    const parsed = parseSessionLink(text.slice(start, end));
    // A link already inside a chip (`nook-context://`) is never bare: it sits in `(…)` after `]`.
    const inChip = start > 0 && text[start - 1] === "(" && text.lastIndexOf("](", start) === start - 2;
    if (parsed && !inChip) found.push({ link: parsed, start, end });
    cursor = end;
  }
  return found;
}

/** What a composer's draft becomes when a session link was pasted into it: each bare link turns into the session's
 * mention (`@title`, the same as picking it after `@`), with the references to add to the composer's mentions. Null
 * when there is nothing to change. */
export function replacingPasted(old: string, next: string): { text: string; refs: ContextRef[] } | null {
  const added = findSessionLinks(next);
  if (!added.length || added.length <= findSessionLinks(old).length) return null;
  let text = next;
  for (const item of [...added].reverse()) {
    text = text.slice(0, item.start) + mentionToken(sessionRef(item.link)) + text.slice(item.end);
  }
  return { text, refs: added.map((a) => sessionRef(a.link)) };
}
