// What the Android companion saw last of each paired computer, as the iPhone's `CompanionCache`: the session list with
// when the computer answered it, the conversations of the last sessions that were open, Nook's chats and the Chats tab's
// chats with the messages of the last ones that were open. So the app shows them at once, also while the computer cannot
// be reached at all, marked as not live. Kept in the app's own storage (`localStorage` of its web view, which only this
// app reads), one entry per computer; anything that cannot be read starts empty.
import type { ChatDigest, ChatLine, InboxChatDigest, InboxLine, LaunchOptions, SessionDigest, TimelineEntry } from "./companion";

export interface Kept<T> { id: string; lines: T[]; saved: number }

export interface CompanionCache {
  /** When the computer answered the list (seconds since 1970); 0 when there is none. */
  saved: number;
  sessions: SessionDigest[];
  /** What a new session can start with, so one can be written (and wait in the outbox) while the computer is away. */
  launch?: LaunchOptions;
  /** The most recently saved first. */
  timelines: Kept<TimelineEntry>[];
  conversations: ChatDigest[];
  chatLines: Kept<ChatLine>[];
  inbox: InboxChatDigest[];
  inboxLines: Kept<InboxLine>[];
}

export const MAX_TIMELINES = 5;
export const MAX_ENTRIES = 200;
export const MAX_CHATS = 8;
export const MAX_LINES = 200;

export function emptyCache(): CompanionCache {
  return { saved: 0, sessions: [], timelines: [], conversations: [], chatLines: [], inbox: [], inboxLines: [] };
}

/** A cache read back, with every part it lacks (an older version, a damaged entry) empty. */
export function readCache(raw: unknown): CompanionCache {
  const c = (raw && typeof raw === "object" ? raw : {}) as Partial<CompanionCache>;
  const list = <T>(v: T[] | undefined) => (Array.isArray(v) ? v : []);
  return {
    saved: typeof c.saved === "number" ? c.saved : 0,
    launch: c.launch && typeof c.launch === "object" ? c.launch : undefined,
    sessions: list(c.sessions), timelines: list(c.timelines), conversations: list(c.conversations),
    chatLines: list(c.chatLines), inbox: list(c.inbox), inboxLines: list(c.inboxLines),
  };
}

/** Keeps a list the computer answered at `at`; an older one than what is kept changes nothing. True when it is worth
 * writing: the list changed, or the time it says ("Last updated") moved on a minute, so a list every few seconds that
 * stays the same writes nothing. */
export function recordSessions(cache: CompanionCache, sessions: SessionDigest[], at: number): boolean {
  if (at < cache.saved) return false;
  const changed = JSON.stringify(sessions) !== JSON.stringify(cache.sessions);
  const minute = Math.floor(at / 60) !== Math.floor(cache.saved / 60);
  cache.saved = at;
  cache.sessions = sessions;
  return changed || minute;
}

function keep<T>(kept: Kept<T>[], id: string, lines: T[], at: number, maxKept: number, maxLines: number): Kept<T>[] | null {
  const old = kept.find((k) => k.id === id);
  const next = lines.slice(-maxLines);
  if (old && (old.saved > at || JSON.stringify(old.lines) === JSON.stringify(next))) return null;
  const rest = kept.filter((k) => k.id !== id);
  return (next.length ? [{ id, lines: next, saved: at }, ...rest] : rest).slice(0, maxKept);
}

/** Keeps a session's conversation (its newest entries) as the most recent; the oldest kept one goes past the limit. */
export function recordTimeline(cache: CompanionCache, session: string, entries: TimelineEntry[], at: number): boolean {
  const next = keep(cache.timelines, session, entries, at, MAX_TIMELINES, MAX_ENTRIES);
  if (next) cache.timelines = next;
  return !!next;
}

/** Keeps Nook's chats, as settled: read later, a chat kept as busy would claim Nook is still writing. */
export function recordConversations(cache: CompanionCache, list: ChatDigest[]): boolean {
  const settled = list.map((c) => ({ ...c, busy: false }));
  if (JSON.stringify(settled) === JSON.stringify(cache.conversations)) return false;
  cache.conversations = settled;
  return true;
}

/** Keeps the newest messages of a Nook chat; an answer that was still streaming is kept as it was, settled. */
export function recordChatLines(cache: CompanionCache, chat: string, lines: ChatLine[], at: number): boolean {
  const settled = lines.map((l) => ({ ...l, streaming: false, status: "" }));
  const next = keep(cache.chatLines, chat, settled, at, MAX_CHATS, MAX_LINES);
  if (next) cache.chatLines = next;
  return !!next;
}

/** Keeps the Chats tab's chats, without who was typing (that is never true later). */
export function recordInbox(cache: CompanionCache, list: InboxChatDigest[]): boolean {
  const settled = list.map(({ typing: _typing, ...c }) => c);
  if (JSON.stringify(settled) === JSON.stringify(cache.inbox)) return false;
  cache.inbox = settled;
  return true;
}

/** Keeps the newest messages of a chat of the Chats tab. */
export function recordInboxLines(cache: CompanionCache, chat: string, lines: InboxLine[], at: number): boolean {
  const next = keep(cache.inboxLines, chat, lines, at, MAX_CHATS, MAX_LINES);
  if (next) cache.inboxLines = next;
  return !!next;
}

/** The id of the computer the phone talks to now, which its cache is kept under. */
export const activeMac = (view: { macs?: { id: string; active: boolean }[] } | null | undefined) => view?.macs?.find((m) => m.active)?.id;

export const kept = <T>(list: Kept<T>[], id: string): T[] | null => list.find((k) => k.id === id)?.lines ?? null;

// MARK: Storage, per computer, written a moment after a burst of changes.

const key = (mac: string) => `companion.cache.${mac}`;
const loaded = new Map<string, CompanionCache>();
const pending = new Map<string, ReturnType<typeof setTimeout>>();

/** The cache of a computer (by the id of its pairing), read once and then kept in memory. */
export function cacheFor(mac: string | undefined): CompanionCache | null {
  if (!mac) return null;
  let cache = loaded.get(mac);
  if (!cache) {
    try {
      const raw = localStorage.getItem(key(mac));
      cache = raw ? readCache(JSON.parse(raw)) : emptyCache();
    } catch {
      cache = emptyCache();
    }
    loaded.set(mac, cache);
  }
  return cache;
}

/** Writes a computer's cache two seconds from now, once for a burst of changes (a conversation that streams). */
export function saveSoon(mac: string | undefined) {
  if (!mac || pending.has(mac)) return;
  pending.set(mac, setTimeout(() => {
    pending.delete(mac);
    const cache = loaded.get(mac);
    if (!cache) return;
    try { localStorage.setItem(key(mac), JSON.stringify(cache)); } catch { /* full or unavailable: kept for this visit */ }
  }, 2000));
}

/** Forgets what was kept of a computer that is no longer paired. */
export function forgetCache(mac: string) {
  clearTimeout(pending.get(mac));
  pending.delete(mac);
  loaded.delete(mac);
  try { localStorage.removeItem(key(mac)); } catch { /* nothing kept */ }
}
