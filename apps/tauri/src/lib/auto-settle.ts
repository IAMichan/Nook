// When a session settles by itself (the Mac's `AutoSettlePolicy`, Settings › Sessions › Tidying up): a session quiet
// for longer than N days moves to Done, or immediately when its pull request is merged or closed (AG-110).
// The blockers are the point: nothing that still runs, waits for you, has an open pull request (when configured),
// or that you pinned or snoozed disappears behind your back, and a session you brought back from Done stays until
// something new happens in it. Also includes Settle actions (AG-111): stopping dev servers, closing idle terminals,
// and running a custom shell command when the last session in a folder settles.
import { needsYou, settle, type InboxRow, type InboxState } from "./agent-inbox";

export type PullRequestState = "none" | "open" | "merged" | "closed";

export type SettleableRow = InboxRow & {
  pullRequest?: PullRequestState;
};

export interface AutoSettleRules {
  enabled: boolean;
  /// Quiet for longer than this many days settles (1…30).
  inactivityDays: number;
  /// Settle immediately when the session's pull request is merged (AG-110).
  settleOnMergedPullRequest?: boolean;
  /// Settle immediately when the session's pull request is closed without merging (AG-110).
  settleOnClosedPullRequest?: boolean;
  /// Never auto-settle while the session has an open pull request (AG-110).
  keepWithOpenPullRequest?: boolean;
}

/// What a new install starts with on the Mac (`newInstallDefaults`): quiet sessions settle after a week, and merged/closed PRs settle automatically.
export const DEFAULT_RULES: Required<AutoSettleRules> = {
  enabled: true,
  inactivityDays: 7,
  settleOnMergedPullRequest: true,
  settleOnClosedPullRequest: true,
  keepWithOpenPullRequest: false,
};
export const MIN_DAYS = 1;
export const MAX_DAYS = 30;
export const RULES_KEY = "nook.autoSettle";
/// The sessions Nook settled, with their newest activity then: reopened by you, one stays until it is active again.
export const SETTLED_KEY = "nook.autoSettle.settled";
export const SETTLE_ACTIONS_KEY = "nook.settleActions";

const DAY = 86_400_000;

export function cleanedRules(raw: unknown): Required<AutoSettleRules> {
  const r = (raw && typeof raw === "object" ? raw : {}) as Partial<AutoSettleRules>;
  const days = Number.isFinite(r.inactivityDays) ? Math.round(r.inactivityDays as number) : DEFAULT_RULES.inactivityDays;
  const merged = typeof r.settleOnMergedPullRequest === "boolean" ? r.settleOnMergedPullRequest : DEFAULT_RULES.settleOnMergedPullRequest;
  const closed = typeof r.settleOnClosedPullRequest === "boolean" ? r.settleOnClosedPullRequest : merged;
  return {
    enabled: typeof r.enabled === "boolean" ? r.enabled : DEFAULT_RULES.enabled,
    inactivityDays: Math.min(MAX_DAYS, Math.max(MIN_DAYS, days)),
    settleOnMergedPullRequest: merged,
    settleOnClosedPullRequest: closed,
    keepWithOpenPullRequest: typeof r.keepWithOpenPullRequest === "boolean" ? r.keepWithOpenPullRequest : DEFAULT_RULES.keepWithOpenPullRequest,
  };
}

export function loadRules(): Required<AutoSettleRules> {
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

export type KeepReason =
  | "disabled"
  | "alreadySettled"
  | "reopenedByYou"
  | "pinned"
  | "needsYou"
  | "working"
  | "snoozed"
  | "openPullRequest"
  | "recentActivity";
export type Decision = { settle: true } | { settle: false; reason: KeepReason };

const keep = (reason: KeepReason): Decision => ({ settle: false, reason });

/// One row: settle it now, or why it stays. `autoSettled` holds the rows Nook settled before.
export function decide(row: SettleableRow, state: InboxState, rules: AutoSettleRules, autoSettled: Record<string, number>, now: number): Decision {
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

  const settleMerged = rules.settleOnMergedPullRequest ?? DEFAULT_RULES.settleOnMergedPullRequest;
  const settleClosed = rules.settleOnClosedPullRequest ?? settleMerged;
  const keepOpen = rules.keepWithOpenPullRequest ?? DEFAULT_RULES.keepWithOpenPullRequest;

  if (row.pullRequest === "merged" && settleMerged) return { settle: true };
  if (row.pullRequest === "closed" && settleClosed) return { settle: true };
  if (row.pullRequest === "open" && keepOpen) return keep("openPullRequest");

  // No known activity (a session whose times were not read yet) is not old.
  if (!(row.lastActivity > 0)) return keep("recentActivity");
  // A snooze that ran out brought the session back to you: its quiet time counts from then.
  const quietSince = Math.max(row.lastActivity, until ?? 0);
  return quietSince < now - Math.max(MIN_DAYS, rules.inactivityDays) * DAY ? { settle: true } : keep("recentActivity");
}

/// The rows to settle now, applied: the new list state, the remembered auto-settled rows, and the ids settled.
export function autoSettle(rows: SettleableRow[], state: InboxState, rules: AutoSettleRules, autoSettled: Record<string, number>, now: number): { state: InboxState; autoSettled: Record<string, number>; settled: string[] } {
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

// MARK: Settle actions (AG-111)

export interface SettleActionRules {
  stopDevServersOnSettle: boolean;
  closeIdleTerminalsOnSettle: boolean;
  settleCommand: string;
}

export const DEFAULT_SETTLE_ACTIONS: SettleActionRules = {
  stopDevServersOnSettle: false,
  closeIdleTerminalsOnSettle: false,
  settleCommand: "",
};

export function cleanedSettleActions(raw: unknown): SettleActionRules {
  const r = (raw && typeof raw === "object" ? raw : {}) as Partial<SettleActionRules>;
  return {
    stopDevServersOnSettle: typeof r.stopDevServersOnSettle === "boolean" ? r.stopDevServersOnSettle : DEFAULT_SETTLE_ACTIONS.stopDevServersOnSettle,
    closeIdleTerminalsOnSettle: typeof r.closeIdleTerminalsOnSettle === "boolean" ? r.closeIdleTerminalsOnSettle : DEFAULT_SETTLE_ACTIONS.closeIdleTerminalsOnSettle,
    settleCommand: typeof r.settleCommand === "string" ? r.settleCommand : DEFAULT_SETTLE_ACTIONS.settleCommand,
  };
}

export function loadSettleActions(): SettleActionRules {
  try { return cleanedSettleActions(JSON.parse(localStorage.getItem(SETTLE_ACTIONS_KEY) ?? "null")); } catch { return DEFAULT_SETTLE_ACTIONS; }
}

export function saveSettleActions(actions: SettleActionRules) {
  try { localStorage.setItem(SETTLE_ACTIONS_KEY, JSON.stringify(cleanedSettleActions(actions))); } catch { /* defaults stay */ }
}

export interface SettleActionPlan {
  folder: string;
  stopDevServers: boolean;
  closeIdleTerminals: boolean;
  command: string | null;
}

/// Plans what settle actions to run for `settledFolder`: actions only run when no other unsettled session still works in the same folder.
export function planSettleActions(
  settledFolder: string,
  otherUnsettledFolders: string[],
  actions: SettleActionRules,
): SettleActionPlan | null {
  const norm = settledFolder.trim().replace(/[\\/]+$/, "");
  if (!norm) return null;
  const cmd = actions.settleCommand.trim();
  if (!actions.stopDevServersOnSettle && !actions.closeIdleTerminalsOnSettle && !cmd) return null;
  const shared = otherUnsettledFolders.some((f) => f.trim().replace(/[\\/]+$/, "") === norm);
  if (shared) return null;
  return {
    folder: norm,
    stopDevServers: actions.stopDevServersOnSettle,
    closeIdleTerminals: actions.closeIdleTerminalsOnSettle,
    command: cmd || null,
  };
}

