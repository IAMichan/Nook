// What the user needs to know or decide, and when: snooze, focus modes, "Catch me up" and the notification history.
// Pure functions over `InboxItem`s so every surface (Home, the bar, a future notch) gets the same answers; the live
// state lives in `inbox.svelte.ts`.
import { tier, type InboxItem, type InboxSource } from "./inbox";

// ---- Snooze -------------------------------------------------------------------------------------------------------

export type SnoozeChoice = "hour" | "tomorrow" | "week";

/// When a snoozed item comes back: in an hour, tomorrow at 08:00, or next Monday at 08:00 (local time).
export function snoozeUntil(choice: SnoozeChoice, now: Date): Date {
  if (choice === "hour") return new Date(now.getTime() + 3_600_000);
  const morning = new Date(now);
  morning.setHours(8, 0, 0, 0);
  if (choice === "tomorrow") {
    morning.setDate(morning.getDate() + 1);
  } else {
    const untilMonday = (8 - morning.getDay()) % 7 || 7;
    morning.setDate(morning.getDate() + untilMonday);
  }
  return morning;
}

/// Splits items into those awake now and those still snoozed. A snooze that ran out simply stops applying.
export function splitSnoozed(items: InboxItem[], snoozed: Record<string, string>, now: number): { awake: InboxItem[]; asleep: InboxItem[] } {
  const awake: InboxItem[] = [];
  const asleep: InboxItem[] = [];
  for (const item of items) ((Date.parse(snoozed[item.id] ?? "") || 0) > now ? asleep : awake).push(item);
  return { awake, asleep };
}

/// Drops snoozes that have ended, so the saved map stays small.
export function pruneSnoozed(snoozed: Record<string, string>, now: number): Record<string, string> {
  return Object.fromEntries(Object.entries(snoozed).filter(([, until]) => (Date.parse(until) || 0) > now));
}

// ---- Focus modes --------------------------------------------------------------------------------------------------

export type FocusMode = "all" | "work" | "deep" | "off_hours";
export const FOCUS_MODES: FocusMode[] = ["all", "work", "deep", "off_hours"];

/// Per mode: the sources that may interrupt, and whether only things that need you get through.
const FOCUS: Record<FocusMode, { sources: InboxSource[] | "all"; onlyUrgent: boolean }> = {
  all: { sources: "all", onlyUrgent: false },
  work: { sources: ["agents", "chats", "tasks", "calendar", "messages", "code", "notes", "ai", "system"], onlyUrgent: false },
  deep: { sources: ["agents", "calendar", "code"], onlyUrgent: true },
  off_hours: { sources: ["messages", "calendar", "chats"], onlyUrgent: true },
};

export function parseFocus(value: string | null | undefined): FocusMode {
  return FOCUS_MODES.includes(value as FocusMode) ? (value as FocusMode) : "all";
}

/// Whether an item may interrupt in this mode. Held items are not lost: they wait under "held back by focus".
export function allowedIn(mode: FocusMode, item: InboxItem): boolean {
  const rule = FOCUS[mode];
  if (rule.sources !== "all" && !rule.sources.includes(item.source)) return false;
  return !rule.onlyUrgent || tier(item) <= 1;
}

export function splitByFocus(items: InboxItem[], mode: FocusMode): { allowed: InboxItem[]; held: InboxItem[] } {
  const allowed: InboxItem[] = [];
  const held: InboxItem[] = [];
  for (const item of items) (allowedIn(mode, item) ? allowed : held).push(item);
  return { allowed, held };
}

/// A gentle suggestion by the clock: weekday working hours suggest Work, evenings and weekends Off hours. Nook only
/// offers it; the user decides. `inMeeting` (from the calendar) suggests Deep work while a meeting is on.
export function suggestFocus(now: Date, inMeeting = false): FocusMode {
  if (inMeeting) return "deep";
  const weekend = now.getDay() === 0 || now.getDay() === 6;
  const hour = now.getHours();
  return weekend || hour < 8 || hour >= 19 ? "off_hours" : "work";
}

/// The system's Do Not Disturb wins over every mode: nothing interrupts, the inbox just keeps collecting.
export function interrupts(mode: FocusMode, item: InboxItem, systemDnd: boolean): boolean {
  return !systemDnd && allowedIn(mode, item) && tier(item) <= 1;
}

// ---- Grouping -----------------------------------------------------------------------------------------------------

export interface Group {
  source: InboxSource;
  items: InboxItem[];
}

/// Items grouped by source, the group with the most pressing item first; inside a group the given order is kept.
export function groupBySource(items: InboxItem[]): Group[] {
  const groups = new Map<InboxSource, InboxItem[]>();
  for (const item of items) groups.set(item.source, [...(groups.get(item.source) ?? []), item]);
  const best = (g: InboxItem[]) => Math.min(...g.map(tier));
  return [...groups].map(([source, list]) => ({ source, items: list })).sort((a, b) => best(a.items) - best(b.items));
}

// ---- Catch me up --------------------------------------------------------------------------------------------------

export interface CatchUp {
  total: number;
  needsYou: number;
  sources: { source: InboxSource; count: number; latest: string }[];
}

/// Everything that happened since `since` (or all of it when the user never looked), per source and overall.
export function catchUp(items: InboxItem[], since: string | null | undefined, now: number): CatchUp {
  const from = Date.parse(since ?? "") || 0;
  const fresh = items.filter((i) => {
    const at = Date.parse(i.at) || 0;
    return at > from && at <= now + 60_000;
  });
  const sources = groupBySource(fresh).map(({ source, items: list }) => ({
    source,
    count: list.length,
    latest: [...list].sort((a, b) => (Date.parse(b.at) || 0) - (Date.parse(a.at) || 0))[0].title,
  }));
  return { total: fresh.length, needsYou: fresh.filter((i) => tier(i) === 0).length, sources };
}

// ---- Notification history -----------------------------------------------------------------------------------------

export interface HistoryEntry {
  id: string;
  source: InboxSource;
  title: string;
  at: string;
}

export const HISTORY_LIMIT = 200;

/// Adds newly seen items to the history (newest first, no duplicates, capped).
export function remember(history: HistoryEntry[], items: InboxItem[]): HistoryEntry[] {
  const known = new Set(history.map((h) => h.id));
  const added = items.filter((i) => !known.has(i.id)).map(({ id, source, title, at }) => ({ id, source, title, at }));
  if (!added.length) return history;
  return [...added, ...history].sort((a, b) => (Date.parse(b.at) || 0) - (Date.parse(a.at) || 0)).slice(0, HISTORY_LIMIT);
}

// ---- Digest -------------------------------------------------------------------------------------------------------

export type DigestKind = "morning" | "evening";

/// The brief to offer right now: the morning brief before noon, the evening wrap-up from 17:00, otherwise none.
export function digestFor(hour: number): DigestKind | null {
  if (hour >= 5 && hour < 12) return "morning";
  if (hour >= 17) return "evening";
  return null;
}

/// What the brief covers: the morning looks at what is still open, the evening at what came in since `since`.
export function digestItems(kind: DigestKind, items: InboxItem[], since: string | null | undefined, now: number): InboxItem[] {
  if (kind === "morning") return items.filter((i) => tier(i) <= 3);
  return catchUp(items, since, now).total ? items.filter((i) => (Date.parse(i.at) || 0) > (Date.parse(since ?? "") || 0)) : [];
}
