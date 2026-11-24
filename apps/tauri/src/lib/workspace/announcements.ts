// What a screen reader hears from the session you look at (the Mac's `AgentAnnouncements`, Settings › Sessions ›
// "Screen reader announcements"): the replies the agent finishes, a question or approval that waits on you, and with
// "Steps and replies" the step it is on. Built on the shared `RunEvent` timeline, so every agent Nook runs gets it. The
// view (`components/SessionAnnouncer.svelte`) puts the words in a polite aria-live region, which Narrator and other
// screen readers read in WebView2; without a screen reader nothing is heard. Pure, so the rules are tested.
import { tr } from "../i18n.svelte";
import type { RunEvent } from "./api";

export type ScreenReaderAnnouncements = "off" | "replies" | "everything";
export const SCREEN_READER_LEVELS: ScreenReaderAnnouncements[] = ["off", "replies", "everything"];

/// A stored value as a level; anything unknown (or nothing) is the Mac's default, replies.
export function announcementLevel(raw: string | null | undefined): ScreenReaderAnnouncements {
  return SCREEN_READER_LEVELS.includes(raw as ScreenReaderAnnouncements) ? (raw as ScreenReaderAnnouncements) : "replies";
}

export type AnnounceStatus = "working" | "approval" | "question" | "idle";

export interface Reply {
  id: string;
  /// Markdown.
  text: string;
  /// The agent stopped writing it: it went on working after it, or the turn ended.
  finished: boolean;
}

export interface Snapshot {
  status: AnnounceStatus;
  /// The step the agent is on, in words; null when it does not work.
  step: string | null;
  /// The agent's replies in the latest turn, oldest first.
  replies: Reply[];
}

export interface Memory {
  status: AnnounceStatus;
  step: string | null;
  /// The replies seen, and whether each was finished then.
  replies: Record<string, boolean>;
  /// The session was seen working while it was open: only then are its replies new rather than history.
  sawWork: boolean;
}

export interface Next {
  memory: Memory;
  /// Said at once, in this order: finished replies, then what waits on you.
  messages: string[];
  /// The step to say once the reader is quiet; null when there is no new one.
  step: string | null;
}

/// Long enough to hear what the agent wrote; the rest is in the conversation.
export const REPLY_LIMIT = 600;

/// The first snapshot of a session is a silent baseline: opening a session reads nothing out.
export function next(previous: Memory | null, snapshot: Snapshot, level: ScreenReaderAnnouncements, author: string): Next {
  const working = snapshot.status === "working";
  const memory: Memory = {
    status: snapshot.status,
    step: working ? snapshot.step : null,
    replies: Object.fromEntries(snapshot.replies.map((r) => [r.id, r.finished])),
    sawWork: (previous?.sawWork ?? false) || snapshot.status !== "idle",
  };
  if (!previous || level === "off") return { memory, messages: [], step: null };
  const messages: string[] = [];
  // A turn that ended before you opened the session is history, however late its transcript arrives.
  if (memory.sawWork) {
    for (const reply of snapshot.replies) {
      if (!reply.finished || previous.replies[reply.id] === true) continue;
      const text = spoken(reply.text);
      if (text) messages.push(tr("{author}: {text}", "{author}: {text}", { author, text }));
    }
  }
  if (snapshot.status !== previous.status) {
    if (snapshot.status === "approval") messages.push(tr("{author} wacht op je goedkeuring", "{author} needs your approval", { author }));
    if (snapshot.status === "question") messages.push(tr("{author} stelt je een vraag", "{author} asks you a question", { author }));
  }
  const step = level === "everything" && working && memory.step !== previous.step ? memory.step : null;
  return { memory, messages, step };
}

/// A reply as it is read: plain words without Markdown, cut short after `REPLY_LIMIT` characters.
export function spoken(markdown: string): string {
  let text = markdown;
  // Code blocks are not read out word by word.
  text = text.replace(/```[\s\S]*?(```|$)/g, ` ${tr("codeblok", "code block")} `);
  // [label](url) reads as its label, an image as nothing.
  text = text.replace(/!\[[^\]]*\]\([^)]*\)/g, "");
  text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, "$1");
  // Headings, quotes and list marks at the start of a line.
  text = text.replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+/gm, "");
  // Emphasis and inline code marks.
  text = text.replace(/[*_`~]+/g, "");
  text = text.split(/\s+/).filter(Boolean).join(" ");
  if ([...text].length <= REPLY_LIMIT) return text;
  return [...text].slice(0, REPLY_LIMIT).join("").trim() + "… " + tr("Meer in het gesprek.", "More in the conversation.");
}

/// A session Nook runs: its latest turn's replies, and whether it works or waits on you.
export function snapshot(events: RunEvent[], status: AnnounceStatus, step: string | null): Snapshot {
  let start = 0;
  for (let i = events.length - 1; i >= 0; i--) if (events[i].kind === "user") { start = i; break; }
  const turn = events.slice(start);
  const replies: Reply[] = [];
  turn.forEach((e, offset) => {
    if (e.kind !== "assistant" || !e.text.trim()) return;
    replies.push({ id: e.id, text: e.text, finished: status === "idle" || offset < turn.length - 1 });
  });
  return { status, step, replies };
}

/// Spaces out steps: a reply or a request is said at once; a step waits until the reader had time for what came before
/// it (about `perCharacter` a character, at least `gap`, at most `holdLimit` seconds), and a newer step replaces one still
/// waiting, so a quick step can be skipped. Returns when the next step may be said (ms since the epoch).
export const PACE = { gap: 2_000, perCharacter: 50, holdLimit: 15_000 };
export function quietUntil(now: number, said: string[]): number {
  if (!said.length) return now + PACE.gap;
  const chars = said.reduce((n, s) => n + s.length, 0);
  return now + Math.min(PACE.holdLimit, Math.max(PACE.gap, chars * PACE.perCharacter));
}
