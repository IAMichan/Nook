// The Agents tab as on the Mac (`CompanionFeature.agentsTab`, packages/protocol/Sources/CompanionSessions.swift): the
// list's shelves, the session menus in the Mac's order, and several questions answered at once. The same rules as the
// iPhone's (`SessionShelf`, `SessionMenu`, `SessionAnswers`), so both phones show the same.
import type { SessionDigest, SessionQuestion } from "./companion";

export type SessionShelf = "needsYou" | "pinned" | "working" | "active" | "snoozed" | "settled";

/** An approval or a question waits, or the session stopped on something only you can resolve. */
export function needsYou(s: SessionDigest): boolean {
  return s.items.length > 0 || ["approval", "input", "failed", "limited"].includes(s.attention);
}

/** The shelf of a session, as the Mac's `InboxLayout.sections`: what needs you never folds away. */
export function sessionShelf(s: SessionDigest, showWorking: boolean, now = Date.now() / 1000): SessionShelf {
  if (needsYou(s)) return "needsYou";
  if (s.pinned) return "pinned";
  if (s.settled) return "settled";
  if (s.snoozedUntil && s.snoozedUntil > now) return "snoozed";
  if (showWorking && s.attention === "working") return "working";
  return "active";
}

/** The sessions per shelf, newest first within each. */
export function placeSessions(sessions: SessionDigest[], showWorking: boolean, now = Date.now() / 1000): Record<SessionShelf, SessionDigest[]> {
  const shelves: Record<SessionShelf, SessionDigest[]> = { needsYou: [], pinned: [], working: [], active: [], snoozed: [], settled: [] };
  for (const s of [...sessions].sort((a, b) => b.updated - a.updated)) shelves[sessionShelf(s, showWorking, now)].push(s);
  return shelves;
}

/** "copy" stands for the Copy rows (path, branch, id); "snooze" for the snooze moments. */
export type MenuEntry = string;

/** A row's long press, as the Mac's row menu: sections of actions, in its order (`SessionMenu.row`). */
export const ROW_MENU: MenuEntry[][] = [
  ["rename", "pin", "unpin", "settle", "reopen", "snooze"],
  ["fork", "restartAgent", "markUnread", "mainThreadOn", "mainThreadOff"],
  ["copy"],
  ["archive", "delete", "end"],
];

/** The session's own header, as the Mac's (`SessionMenu.header`). */
export const HEADER_MENU: MenuEntry[][] = [
  ["retry", "settle", "reopen"],
  ["rename", "regenerateTitle", "fork", "restartAgent", "mainThreadOn", "mainThreadOff"],
  ["pin", "unpin", "snooze", "markUnread", "copy"],
  ["archive", "delete", "end"],
];

/** The entries of `layout` the session offers, sections without any left out. */
export function menuEntries(layout: MenuEntry[][], offered: string[] | undefined): MenuEntry[][] {
  const set = new Set(offered ?? []);
  const has = (e: MenuEntry) => e === "copy" || (e === "snooze" ? set.has("snoozeHour") || set.has("unsnooze") : set.has(e));
  return layout.map((section) => section.filter(has)).filter((section) => section.length);
}

/** The answers as the Mac takes them: one entry per question, options or (where it takes them) your own words, a single
 * answer where only one may be picked; null when one is missing or not allowed. */
export function validAnswers(answers: Record<string, string[]>, questions: SessionQuestion[]): Record<string, string[]> | null {
  if (!questions.length) return null;
  const out: Record<string, string[]> = {};
  for (const q of questions) {
    const picked = (answers[q.id] ?? []).map((a) => a.trim()).filter(Boolean);
    if (!picked.length || new Set(picked).size !== picked.length) return null;
    if (!q.multiSelect && picked.length > 1) return null;
    if (picked.some((a) => !q.options.includes(a) && !q.allowsOther)) return null;
    out[q.id] = picked;
  }
  return out;
}

/** Picks or unpicks an option: toggled where several count, the only answer otherwise. */
export function toggleAnswer(option: string, picked: string[], multiSelect: boolean): string[] {
  if (!multiSelect) return [option];
  return picked.includes(option) ? picked.filter((p) => p !== option) : [...picked, option];
}
