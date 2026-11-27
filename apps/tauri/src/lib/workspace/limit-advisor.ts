// Which account a session that hit its usage limit can go on with (`LimitAdvisor` in the Mac's AgentAdvice.swift): the
// other accounts with room left, best first: the same agent first (its context and skills carry over), then the least
// used of the rest; accounts whose use is unknown only after those, same agent first again. Accounts that are nearly
// full themselves are left out. When none has room, the least used ones that are not full yet. Data only: the usage
// limit card in the timeline phrases it. No interface code, so tests use it on its own.

export interface LimitState {
  provider: string;
  profileId: string;
  /** 0…1, null when unknown. */
  usedFraction: number | null;
  resetAt: Date | null;
}

export interface LimitSuggestion {
  provider: string;
  profileId: string;
  sameAgent: boolean;
  /** How much of the suggested account's limit is used, 0…1; null when unknown. */
  usedFraction: number | null;
  /** Seconds until the current account resets, for "or wait N". */
  resumeIn: number | null;
}

export const LIMITED_AT = 0.9;
export const FREE_BELOW = 0.7;

type Current = { provider: string; profileId: string };

const isCurrent = (s: LimitState, c: Current) => s.provider === c.provider && s.profileId === c.profileId;

function mine(states: LimitState[], current: Current): LimitState | null {
  const me = states.find((s) => isCurrent(s, current));
  return me && me.usedFraction !== null && me.usedFraction >= LIMITED_AT ? me : null;
}

const resumeIn = (me: LimitState, now: Date) => (me.resetAt ? Math.max(0, (me.resetAt.getTime() - now.getTime()) / 1000) : null);

/** Every account to go on with, best first. Empty while the current account still has room. */
export function limitOptions(states: LimitState[], current: Current, now: Date): LimitSuggestion[] {
  const me = mine(states, current);
  if (!me) return [];
  const others = states.filter((s) => !isCurrent(s, current));
  const known = others
    .filter((s) => (s.usedFraction ?? 1) < FREE_BELOW)
    .sort((a, b) => (a.usedFraction ?? 1) - (b.usedFraction ?? 1));
  const unknown = others.filter((s) => s.usedFraction === null);
  const sameFirst = (list: LimitState[]) => [...list.filter((s) => s.provider === current.provider), ...list.filter((s) => s.provider !== current.provider)];
  const wait = resumeIn(me, now);
  return [...sameFirst(known), ...sameFirst(unknown)].map((s) => ({
    provider: s.provider,
    profileId: s.profileId,
    sameAgent: s.provider === current.provider,
    usedFraction: s.usedFraction,
    resumeIn: wait,
  }));
}

/** The accounts to offer when `limitOptions` has none: the others that are filling up but not full yet, least used
 * first (same agent first when equally used). */
export function limitFallbacks(states: LimitState[], current: Current, now: Date): LimitSuggestion[] {
  const me = mine(states, current);
  if (!me) return [];
  const wait = resumeIn(me, now);
  return states
    .filter((s) => !isCurrent(s, current) && s.usedFraction !== null && s.usedFraction < 1)
    .sort((a, b) => {
      if (a.usedFraction !== b.usedFraction) return a.usedFraction! - b.usedFraction!;
      const sa = a.provider === current.provider ? 0 : 1;
      const sb = b.provider === current.provider ? 0 : 1;
      return sa - sb;
    })
    .map((s) => ({ provider: s.provider, profileId: s.profileId, sameAgent: s.provider === current.provider, usedFraction: s.usedFraction, resumeIn: wait }));
}

/** What the usage limit card offers: the roomy accounts, else the fallbacks. The current account counts as full: it
 * hit the limit. */
export function limitPicks(states: LimitState[], current: Current, now: Date): LimitSuggestion[] {
  const marked = states.some((s) => isCurrent(s, current))
    ? states.map((s) => (isCurrent(s, current) ? { ...s, usedFraction: Math.max(s.usedFraction ?? 0, 1) } : s))
    : [...states, { provider: current.provider, profileId: current.profileId, usedFraction: 1, resetAt: null }];
  const roomy = limitOptions(marked, current, now);
  return roomy.length ? roomy : limitFallbacks(marked, current, now);
}

/** An account's state from its windows (used 0…100): the fullest window decides; none known is unknown. */
export function limitState(provider: string, profileId: string, windows: { used: number; resetsAt: Date | null }[]): LimitState {
  const used = windows.length ? Math.max(...windows.map((w) => w.used)) / 100 : null;
  const resets = windows.map((w) => w.resetsAt).filter((d): d is Date => d !== null);
  const resetAt = resets.length ? new Date(Math.min(...resets.map((d) => d.getTime()))) : null;
  return { provider, profileId, usedFraction: used, resetAt };
}
