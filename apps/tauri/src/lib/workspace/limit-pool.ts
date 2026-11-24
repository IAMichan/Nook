// Every subscription account of one agent read as one pool (`LimitPool` on the Mac): per window (5 hours, week) how
// much of the pool is used and whether it is spent ahead of the clock, with a column per account in the same place
// across windows, and which reset comes next and how much of the pool it hands back. One account is a pool of one.
// No interface code, so tests use it on its own.

export type Pace = "ahead" | "on" | "under";
export type Kind = "session" | "weekly" | "other";
const KIND_ORDER: Record<Kind, number> = { session: 0, weekly: 1, other: 2 };

export interface Limit {
  label: string;
  /** Used, 0…100. */
  used: number;
  resetsAt: Date | null;
  /** Seconds the window lasts, when known. */
  duration: number | null;
}

export interface Account {
  id: string;
  name: string;
  limits: Limit[];
  sessionWeight: number | null;
  weeklyWeight: number | null;
}

export interface Member {
  accountId: string;
  name: string;
  /** Null: the account does not report this window (a gap). */
  limit: Limit | null;
  /** How much of this account its next reset gives back, 0…100. */
  refill: number;
}

export interface Reset { accountId: string; at: Date; restores: number }

export interface Window {
  label: string;
  kind: Kind;
  /** Used of the whole pool, 0…100, weighed by plan size. */
  used: number;
  pace: Pace | null;
  columns: Member[];
  /** The coming resets, soonest first. */
  resets: Reset[];
}

export interface Pool { accounts: Account[]; windows: Window[] }

export function kindOf(duration: number | null): Kind {
  if (duration === null) return "other";
  if (duration <= 24 * 3600) return "session";
  if (duration <= 8 * 86_400) return "weekly";
  return "other";
}

/** The model group of a label like "Gemini 4 Argon · Week", or null for a plain window ("Week"). */
function group(label: string): string | null {
  const at = label.lastIndexOf(" · ");
  return at >= 0 ? label.slice(0, at) : null;
}

const clamp = (n: number) => Math.max(0, Math.min(100, n));
/** What is left, rounded as it is shown. */
export const left = (used: number) => Math.round(100 - clamp(used));

/** How far `now` is into the window, 0…1; null without a clock. */
export function elapsedShare(limit: Limit, now: Date): number | null {
  if (!limit.resetsAt || !limit.duration || limit.duration <= 0) return null;
  return Math.max(0, Math.min(1, (limit.duration - (limit.resetsAt.getTime() - now.getTime()) / 1000) / limit.duration));
}

/** The window's time gone by, 0…100: where the even-pace line sits on a bar of what was used. */
export function timeElapsed(limit: Limit, now: Date): number | null {
  const share = elapsedShare(limit, now);
  return share === null ? null : 100 - Math.round((1 - share) * 100);
}

export function paceOf(used: number, elapsed: number): Pace {
  const gap = used - elapsed * 100;
  return gap > 5 ? "ahead" : gap < -5 ? "under" : "on";
}

/**
 * An account's window as the pool counts it. While the account's week of the same model group is spent, its session
 * window is spent too: it reads as full, without a pace, and comes back with whichever of the two resets frees it.
 */
export function member(account: Account, limit: Limit, now: Date): Member {
  const plain: Member = { accountId: account.id, name: account.name, limit, refill: limit.used };
  if (kindOf(limit.duration) !== "session") return plain;
  const week = account.limits.find((l) => kindOf(l.duration) === "weekly" && group(l.label) === group(limit.label) && l.used >= 100);
  if (!week) return plain;
  const spent: Limit = { ...limit, used: 100, duration: null, resetsAt: null };
  let refill = 0;
  if (week.resetsAt && limit.resetsAt && week.resetsAt > now && limit.resetsAt > now) {
    if (limit.resetsAt <= week.resetsAt) { spent.resetsAt = week.resetsAt; refill = 100; }
    else if (limit.used >= 100) { spent.resetsAt = limit.resetsAt; refill = 100; }
    else { spent.resetsAt = week.resetsAt; refill = 100 - clamp(limit.used); }
  }
  return { accountId: account.id, name: account.name, limit: spent, refill };
}

/**
 * How large a plan is next to the agent's smallest paid plan, per window kind: Claude's plans multiply the session
 * allowance only (Pro 1, Max 5x 5, Max 20x 20), ChatGPT's the session and the week alike (Plus 1, Pro 20, Pro Lite 5).
 */
export function weights(agent: string, plan: string): { session: number | null; weekly: number | null } {
  const p = plan.toLowerCase();
  if (!p) return { session: null, weekly: null };
  if (agent === "claude") {
    const size = p.includes("20x") || p.includes("ultra") ? 20 : p.includes("5x") || p.includes("max") ? 5 : p.includes("pro") ? 1 : null;
    return { session: size, weekly: null };
  }
  if (agent === "codex") {
    const size = p.includes("plus") ? 1 : p.includes("pro") ? (p.includes("100") || p.includes("lite") ? 5 : 20) : null;
    return { session: size, weekly: size };
  }
  return { session: null, weekly: null };
}

const weightOf = (a: Account, kind: Kind) => (kind === "session" ? a.sessionWeight : kind === "weekly" ? a.weeklyWeight : null);

/** Null when no account reports a limit. */
export function makePool(accounts: Account[], now: Date = new Date()): Pool | null {
  const reporting = accounts.filter((a) => a.limits.length);
  if (!reporting.length) return null;
  const all = reporting.flatMap((a) => a.limits);
  const first = all.reduce<Limit | null>((m, l) => (!m || KIND_ORDER[kindOf(l.duration)] < KIND_ORDER[kindOf(m.duration)] ? l : m), null);
  const firstReset = (a: Account) => {
    const limit = first && a.limits.find((l) => l.label === first.label);
    return limit ? (member(a, limit, now).limit?.resetsAt?.getTime() ?? Infinity) : Infinity;
  };
  const order = [...reporting].sort((a, b) => firstReset(a) - firstReset(b) || a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
  const labels: string[] = [];
  for (const a of order) for (const l of a.limits) if (!labels.includes(l.label)) labels.push(l.label);

  const windows = labels.map((label): Window => {
    const columns = order.map((a): Member => {
      const limit = a.limits.find((l) => l.label === label);
      return limit ? member(a, limit, now) : { accountId: a.id, name: a.name, limit: null, refill: 0 };
    });
    const kind = kindOf(order.map((a) => a.limits.find((l) => l.label === label)).find(Boolean)?.duration ?? null);
    const members = columns.filter((m) => m.limit);
    const sizes = members.map((m) => weightOf(order.find((a) => a.id === m.accountId)!, kind));
    const ws = sizes.every((s) => (s ?? 0) > 0) ? sizes.map((s) => s ?? 1) : members.map(() => 1);
    const total = Math.max(ws.reduce((a, b) => a + b, 0), 1);
    const used = members.reduce((sum, m, i) => sum + m.limit!.used * ws[i], 0) / total;
    const timed = members.flatMap((m, i) => {
      const e = elapsedShare(m.limit!, now);
      return e === null ? [] : [{ used: m.limit!.used, elapsed: e, weight: ws[i] }];
    });
    const timedWeight = timed.reduce((a, t) => a + t.weight, 0);
    const pace = !timed.length || timedWeight <= 0 ? null
      : paceOf(timed.reduce((a, t) => a + t.used * t.weight, 0) / timedWeight, timed.reduce((a, t) => a + t.elapsed * t.weight, 0) / timedWeight);
    const resets = members
      .flatMap((m, i): Reset[] => (m.limit!.resetsAt && m.limit!.resetsAt > now ? [{ accountId: m.accountId, at: m.limit!.resetsAt, restores: Math.round((m.refill * ws[i]) / total) }] : []))
      .sort((a, b) => a.at.getTime() - b.at.getTime());
    return { label, kind, used: 100 - left(used), pace, columns, resets };
  });
  const sorted = windows.map((w, i) => [w, i] as const).sort((a, b) => KIND_ORDER[a[0].kind] - KIND_ORDER[b[0].kind] || a[1] - b[1]).map(([w]) => w);
  return { accounts: order, windows: sorted };
}

/** The first reset that gives anything back. */
export const nextRefill = (w: Window) => w.resets.find((r) => r.restores > 0) ?? null;

export const FIVE_HOURS = 5 * 3600;
export const WEEK = 7 * 86_400;

/** Used percentage rounded the same way as the pool (`100 - left(used)`), so 38.5% matches everywhere. */
export const usedOf = (used: number): number => 100 - left(used);

export type UsageToneLevel = "calm" | "warning" | "error";

/** How full a limit is colored: calm while there is room, amber from 75% used, coral from 90% (`UsageTone`). */
export function usageTone(used: number): UsageToneLevel {
  const n = Math.round(used);
  return n >= 90 ? "error" : n >= 75 ? "warning" : "calm";
}

/** Spending pace of a single window against its elapsed clock. */
export function paceForLimit(limit: Limit, now: Date): Pace | null {
  const share = elapsedShare(limit, now);
  return share === null ? null : paceOf(limit.used, share);
}

/** A limit window as displayed in rows and pools, with an optional idle note ("Starts with your first message"). */
export interface LimitDisplay extends Limit {
  note: string | null;
}

/** Groups limits by model prefix ("Gemini 3 Pro · Week" → group "Gemini 3 Pro", window "Week"). */
export function groupLimits(limits: LimitDisplay[]): { name: string; limits: (LimitDisplay & { window: string })[] }[] {
  const groups: { name: string; limits: (LimitDisplay & { window: string })[] }[] = [];
  for (const limit of limits) {
    const at = limit.label.lastIndexOf(" · ");
    const name = at >= 0 ? limit.label.slice(0, at) : "";
    const window = at >= 0 ? limit.label.slice(at + 3) : limit.label;
    let bucket = groups.find((g) => g.name === name);
    if (!bucket) {
      bucket = { name, limits: [] };
      groups.push(bucket);
    }
    bucket.limits.push({ ...limit, window });
  }
  return groups;
}

/** Structural input matching `AccountLimits` without pulling in Tauri runtime dependencies. */
export interface AccountLimitInput {
  profileId: string;
  kind: string;
  name: string;
  email: string | null;
  plan: string;
  apiKey: boolean;
  usage: {
    fiveHour: { usedPercent: number; resetsAt: string } | null;
    sevenDay: { usedPercent: number; resetsAt: string } | null;
  } | null;
  codex: {
    fiveHour: { usedPercent: number; resetsAt: string | null; windowMinutes: number | null } | null;
    weekly: { usedPercent: number; resetsAt: string | null; windowMinutes: number | null } | null;
    resetCredits: { available: number; nextExpiresAt: string | null } | null;
  } | null;
  antigravityLimits: {
    label: string;
    percent: number;
    resetsAt: string | null;
    note: string | null;
    durationSecs: number | null;
  }[];
  antigravityNoLogin: boolean;
}

export interface LimitLabels {
  fiveHours: string;
  week: string;
  startsFirst: string;
}

function parseDate(iso: string | null | undefined): Date | null {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? null : d;
}

function settleWindow(
  label: string,
  used: number,
  resetsAt: Date | null,
  duration: number | null,
  note: string | null,
  startsFirst: string,
  now: Date,
  checkUnstarted: boolean,
): LimitDisplay {
  const clamped = clamp(used);
  if (resetsAt) {
    const remainingSecs = (resetsAt.getTime() - now.getTime()) / 1000;
    const passed = remainingSecs <= 0;
    const unstarted = checkUnstarted && clamped < 0.5 && duration !== null && remainingSecs > duration - 15 * 60;
    if (passed || unstarted) {
      return { label, used: 0, resetsAt: null, duration, note: startsFirst };
    }
  }
  return { label, used: clamped, resetsAt, duration, note };
}

/** Converts one account's raw backend limits into settled display/pool windows. */
export function accountLimitsToPoolLimits(
  account: AccountLimitInput,
  labels: LimitLabels,
  now: Date = new Date(),
): LimitDisplay[] {
  if (account.apiKey) return [];
  if (account.kind === "antigravity") {
    return account.antigravityLimits.map((l) =>
      settleWindow(l.label, l.percent, parseDate(l.resetsAt), l.durationSecs, l.note, labels.startsFirst, now, true),
    );
  }
  if (account.kind === "codex" && account.codex) {
    const out: LimitDisplay[] = [];
    if (account.codex.fiveHour) {
      const w = account.codex.fiveHour;
      const duration = w.windowMinutes && w.windowMinutes > 0 ? w.windowMinutes * 60 : FIVE_HOURS;
      out.push(settleWindow(labels.fiveHours, w.usedPercent, parseDate(w.resetsAt), duration, null, labels.startsFirst, now, false));
    }
    if (account.codex.weekly) {
      const w = account.codex.weekly;
      const duration = w.windowMinutes && w.windowMinutes > 0 ? w.windowMinutes * 60 : WEEK;
      out.push(settleWindow(labels.week, w.usedPercent, parseDate(w.resetsAt), duration, null, labels.startsFirst, now, false));
    }
    return out;
  }
  if (account.usage) {
    const out: LimitDisplay[] = [];
    if (account.usage.fiveHour) {
      const w = account.usage.fiveHour;
      out.push(settleWindow(labels.fiveHours, w.usedPercent, parseDate(w.resetsAt), FIVE_HOURS, null, labels.startsFirst, now, false));
    }
    if (account.usage.sevenDay) {
      const w = account.usage.sevenDay;
      out.push(settleWindow(labels.week, w.usedPercent, parseDate(w.resetsAt), WEEK, null, labels.startsFirst, now, false));
    }
    return out;
  }
  return [];
}

export interface LimitAccountDetails {
  email: string | null;
  plan: string | null;
  credits: number;
}

export interface PoolSection {
  kind: string;
  pool: Pool;
  details: Record<string, LimitAccountDetails>;
}

const AGENT_ORDER = ["claude", "codex", "gemini", "antigravity", "opencode", "cursor", "grok"];

/** Builds per-agent pooled sections and unavailable notices (`UsageLimitSection.make` on the Mac). */
export function buildPoolSections(
  accounts: AccountLimitInput[],
  options: {
    now?: Date;
    hidden?: Set<string>;
    labels: LimitLabels;
    agentName: (kind: string) => string;
    unavailableReason: (account: AccountLimitInput) => string;
    formatNotice: (accountTitle: string, reason: string) => string;
  },
): { sections: PoolSection[]; notices: string[] } {
  const now = options.now ?? new Date();
  const hidden = options.hidden ?? new Set<string>();
  const visible = accounts.filter((a) => !hidden.has(a.kind));
  const byKind = new Map<string, AccountLimitInput[]>();
  for (const a of visible) {
    const list = byKind.get(a.kind) ?? [];
    list.push(a);
    byKind.set(a.kind, list);
  }
  const kinds = [...byKind.keys()].sort((a, b) => {
    const ia = AGENT_ORDER.indexOf(a);
    const ib = AGENT_ORDER.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.localeCompare(b);
  });

  const sections: PoolSection[] = [];
  const notices: string[] = [];

  for (const kind of kinds) {
    const groupAccounts = byKind.get(kind) ?? [];
    const details: Record<string, LimitAccountDetails> = {};
    const poolAccounts: Account[] = groupAccounts.map((a) => {
      const limits = accountLimitsToPoolLimits(a, options.labels, now);
      details[a.profileId] = {
        email: a.email,
        plan: a.plan || null,
        credits: a.codex?.resetCredits?.available ?? 0,
      };
      if (!limits.length) {
        const title = a.name && a.name !== options.agentName(kind) ? `${options.agentName(kind)} · ${a.name}` : options.agentName(kind);
        notices.push(options.formatNotice(title, options.unavailableReason(a)));
      }
      const w = weights(kind, a.plan);
      return {
        id: a.profileId,
        name: a.name,
        limits,
        sessionWeight: w.session,
        weeklyWeight: w.weekly,
      };
    });
    const pool = makePool(poolAccounts, now);
    if (pool) {
      sections.push({ kind, pool, details });
    }
  }
  return { sections, notices };
}

