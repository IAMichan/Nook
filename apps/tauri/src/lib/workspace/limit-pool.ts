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
