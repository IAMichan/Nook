// When a session settles by itself (the Mac's `AutoSettlePolicy`, Settings › Sessions › Tidying up): a session quiet
// for longer than N days moves to Done. The blockers are the point: nothing that still runs, waits for you, or that you
// pinned or snoozed disappears behind your back, and a session you brought back from Done stays until something new
// happens in it. The rules and the sessions Nook settled are kept for every window in localStorage. Pure, so tested.
//
// Left out on Windows: the Mac's pull-request rules (settle when merged or closed, keep with an open pull request) need
// each session's pull-request state, which the Agents list's run data does not carry; and the rules per machine, since
// Windows has no SSH machines.
import { needsYou, settle, type InboxRow, type InboxState } from "./agent-inbox";

export interface AutoSettleRules {
  enabled: boolean;
  /// Quiet for longer than this many days settles (1…30).
  inactivityDays: number;
}

/// What a new install starts with on the Mac (`newInstallDefaults`): quiet sessions settle after a week.
export const DEFAULT_RULES: AutoSettleRules = { enabled: true, inactivityDays: 7 };
export const MIN_DAYS = 1;
export const MAX_DAYS = 30;
export const RULES_KEY = "nook.autoSettle";
/// The sessions Nook settled, with their newest activity then: reopened by you, one stays until it is active again.
export const SETTLED_KEY = "nook.autoSettle.settled";

const DAY = 86_400_000;

export function cleanedRules(raw: unknown): AutoSettleRules {
  const r = (raw && typeof raw === "object" ? raw : {}) as Partial<AutoSettleRules>;
  const days = Number.isFinite(r.inactivityDays) ? Math.round(r.inactivityDays as number) : DEFAULT_RULES.inactivityDays;
  return {
    enabled: typeof r.enabled === "boolean" ? r.enabled : DEFAULT_RULES.enabled,
    inactivityDays: Math.min(MAX_DAYS, Math.max(MIN_DAYS, days)),
  };
}

export function loadRules(): AutoSettleRules {
  try { return cleanedRules(JSON.parse(localStorage.getItem(RULES_KEY) ?? "null")); } catch { return DEFAULT_RULES; }
}

export function saveRules(rules: AutoSettleRules) {
  try { localStorage.setItem(RULES_KEY, JSON.stringify(cleanedRules(rules))); } catch { /* the defaults stay */ }
}

export function loadSettled(): Record<string, number> {
  try {
    const raw = JSON.parse(localStorage.getItem(SETTLED_KEY) ?? "{}");
    return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
  } catch { return {}; }
}

export function saveSettled(settled: Record<string, number>) {
  try { localStorage.setItem(SETTLED_KEY, JSON.stringify(settled)); } catch { /* remembered until the window closes */ }
}

export type KeepReason = "disabled" | "alreadySettled" | "reopenedByYou" | "pinned" | "needsYou" | "working" | "snoozed" | "recentActivity";
export type Decision = { settle: true } | { settle: false; reason: KeepReason };

const keep = (reason: KeepReason): Decision => ({ settle: false, reason });

/// One row: settle it now, or why it stays. `autoSettled` holds the rows Nook settled before.
export function decide(row: InboxRow, state: InboxState, rules: AutoSettleRules, autoSettled: Record<string, number>, now: number): Decision {
  if (state.settled.includes(row.id)) return keep("alreadySettled");
  if (!rules.enabled) return keep("disabled");
  // You brought it back from Done: it stays until something new happens in it, then the rules apply again.
  const before = autoSettled[row.id];
  if (before !== undefined && row.lastActivity <= before) return keep("reopenedByYou");
  if (state.pinned.includes(row.id)) return keep("pinned");
  if (needsYou(row.attention)) return keep("needsYou");
  if (row.attention === "working" || row.hasBackgroundWork) return keep("working");
  const until = state.snoozed[row.id];
  if (until !== undefined && until > now) return keep("snoozed");
  // No known activity (a session whose times were not read yet) is not old.
  if (!(row.lastActivity > 0)) return keep("recentActivity");
  // A snooze that ran out brought the session back to you: its quiet time counts from then.
  const quietSince = Math.max(row.lastActivity, until ?? 0);
  return quietSince < now - Math.max(MIN_DAYS, rules.inactivityDays) * DAY ? { settle: true } : keep("recentActivity");
}

/// The rows to settle now, applied: the new list state, the remembered auto-settled rows, and the ids settled.
export function autoSettle(rows: InboxRow[], state: InboxState, rules: AutoSettleRules, autoSettled: Record<string, number>, now: number): { state: InboxState; autoSettled: Record<string, number>; settled: string[] } {
  let next = state;
  const remembered = { ...autoSettled };
  const settled: string[] = [];
  for (const row of rows) {
    if (!decide(row, state, rules, autoSettled, now).settle) continue;
    next = settle(next, row.id);
    remembered[row.id] = row.lastActivity;
    settled.push(row.id);
  }
  return { state: next, autoSettled: remembered, settled };
}
