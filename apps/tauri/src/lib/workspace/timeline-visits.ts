// When you last looked at each session's conversation and the folds you had open (`TimelineVisits` and
// `TimelineLanding` on the Mac), so coming back lands at the end with a line above what is new since, and the folds you
// opened are open again. Kept on this computer, bounded: the least recently viewed go first. No interface code, so
// tests use it on its own.

export interface TimelineVisit {
  /** Folds, groups and events you had open. */
  open: string[];
  /** When you left the conversation (ms). */
  lastViewedAt: number;
}

export const VISIT_LIMIT = 200;
/** Open folds kept per session: a reader opens a few, not hundreds. */
export const OPEN_LIMIT = 200;
const KEY = "nook.timelineVisits";

export type Visits = Record<string, TimelineVisit>;

/** Tolerant: what cannot be read is no visit. */
export function parseVisits(text: string | null): Visits {
  if (!text) return {};
  try {
    const raw = JSON.parse(text) as Record<string, unknown>;
    const out: Visits = {};
    for (const [id, v] of Object.entries(raw ?? {})) {
      const visit = v as Partial<TimelineVisit> | null;
      if (!visit || typeof visit !== "object") continue;
      out[id] = {
        open: Array.isArray(visit.open) ? visit.open.filter((x): x is string => typeof x === "string") : [],
        lastViewedAt: typeof visit.lastViewedAt === "number" ? visit.lastViewedAt : 0,
      };
    }
    return out;
  } catch {
    return {};
  }
}

export function remember(visits: Visits, sessionId: string, visit: TimelineVisit): Visits {
  const open = visit.open.length > OPEN_LIMIT ? [...visit.open].sort().slice(0, OPEN_LIMIT) : visit.open;
  const next: Visits = { ...visits, [sessionId]: { open, lastViewedAt: visit.lastViewedAt } };
  const ids = Object.keys(next);
  if (ids.length > VISIT_LIMIT) {
    ids
      .sort((a, b) => next[a].lastViewedAt - next[b].lastViewedAt || (a < b ? -1 : 1))
      .slice(0, ids.length - VISIT_LIMIT)
      .forEach((id) => delete next[id]);
  }
  return next;
}

/** The first row newer than `since`, when something older comes before it (there is nothing to set it apart from
 * otherwise). Rows without a time of their own count as old. */
export function firstNew(rows: { id: string; date: number | null }[], since: number): string | null {
  const index = rows.findIndex((r) => (r.date ?? -Infinity) > since);
  return index > 0 ? rows[index].id : null;
}

export function loadVisit(sessionId: string): TimelineVisit | null {
  try {
    return parseVisits(localStorage.getItem(KEY))[sessionId] ?? null;
  } catch {
    return null;
  }
}

export function saveVisit(sessionId: string, visit: TimelineVisit) {
  try {
    localStorage.setItem(KEY, JSON.stringify(remember(parseVisits(localStorage.getItem(KEY)), sessionId, visit)));
  } catch {
    /* No storage: the next visit opens without a line. */
  }
}
