// Home's inbox: the few things that happened while you were not looking, from every part of Nook. This file is the
// model and the deterministic ranking; `inbox.svelte.ts` keeps the live list and `inbox-sources.ts` adapts each feature.
// A future AI ranking takes the same items and returns them in a new order (`Prioritizer`), so nothing else changes.
import type { Route } from "./shell-routes";

export type InboxSource = "agents" | "chats" | "tasks" | "calendar" | "messages" | "code" | "gamer_mode" | "notes" | "ai" | "system";
export type InboxType = "action_required" | "missed" | "reminder" | "update" | "insight";

/// Where an action takes you. Home turns it into a route change; features never import Home.
export type Target =
  | { kind: "route"; route: Route }
  | { kind: "settings"; section: string }
  | { kind: "workspace"; page: "terminals" | "browser" | "worktrees" | "usage" }
  | { kind: "agents"; select: string }
  | { kind: "nook"; id: string }
  | { kind: "newNook"; ask?: string }
  /// Text to read right on Home (a conversation note).
  | { kind: "markdown"; title: string; markdown: string };

export interface InboxAction {
  id: string;
  label: string;
}

export interface InboxItem {
  /// Stable per occurrence (a new WhatsApp message gets a new id), so a dismissal holds until something new happens.
  id: string;
  /// The provider that made it and handles its actions.
  provider: string;
  /// The provider's own key for the thing (a chat, an open item), for its actions.
  ref?: string;
  source: InboxSource;
  type: InboxType;
  title: string;
  detail?: string;
  /// When it happened, or for a reminder when it is due (ISO).
  at: string;
  /// Something you asked for yourself: a reminder you set, a chat or an agent waiting on you.
  cared?: boolean;
  /// What the source knows beyond the type: 2 urgent (due within the hour), 1 today, 0 the rest.
  weight?: number;
  /// The first is the primary action. "Dismiss" is always there and is not listed.
  actions: InboxAction[];
}

export interface Ranked {
  /// What Home shows, most important first.
  shown: InboxItem[];
  /// The calmer items left out, for "n more".
  rest: InboxItem[];
}

export type Prioritizer = (items: InboxItem[], now: number) => InboxItem[];

/// 0 needs you, 1 you said you care, 2 you missed it, 3 a reminder or update, 4 everything else.
export function tier(item: InboxItem): number {
  if (item.type === "action_required") return 0;
  if (item.cared) return 1;
  if (item.type === "missed") return 2;
  if (item.type === "reminder" || (item.type === "update" && (item.weight ?? 0) > 0)) return 3;
  return 4;
}

/// Same tier: the more urgent first; then a reminder by how soon it is due, anything else newest first.
export const deterministic: Prioritizer = (items, now) =>
  [...items].sort((a, b) => {
    const t = tier(a) - tier(b);
    if (t) return t;
    const w = (b.weight ?? 0) - (a.weight ?? 0);
    if (w) return w;
    const at = Date.parse(a.at) || 0;
    const bt = Date.parse(b.at) || 0;
    return a.type === "reminder" && b.type === "reminder" ? Math.abs(at - now) - Math.abs(bt - now) : bt - at;
  });

/// How many items Home shows at once, and how many of those may be calm ones (tier 4): low-value news never crowds out
/// what needs you.
export const SHOWN = 5;
export const CALM_SHOWN = 2;

export function rank(items: InboxItem[], dismissed: Record<string, string>, now: number, order: Prioritizer = deterministic): Ranked {
  const open = dedupe(items).filter((i) => !(i.id in dismissed));
  const shown: InboxItem[] = [];
  const rest: InboxItem[] = [];
  let calm = 0;
  for (const item of order(open, now)) {
    const quiet = tier(item) === 4;
    if (shown.length < SHOWN && (!quiet || calm < CALM_SHOWN)) {
      shown.push(item);
      if (quiet) calm++;
    } else rest.push(item);
  }
  return { shown, rest };
}

function dedupe(items: InboxItem[]): InboxItem[] {
  const seen = new Set<string>();
  return items.filter((i) => !seen.has(i.id) && (seen.add(i.id), true));
}

/// How long a dismissal is remembered: after that its source no longer reports the item anyway.
export const FORGET_AFTER = 14 * 86_400_000;

export function pruneDismissed(dismissed: Record<string, string>, now: number): Record<string, string> {
  return Object.fromEntries(Object.entries(dismissed).filter(([, at]) => now - (Date.parse(at) || 0) < FORGET_AFTER));
}

export type Daypart = "morning" | "afternoon" | "evening";

export function daypart(hour: number): Daypart {
  if (hour >= 5 && hour < 12) return "morning";
  if (hour >= 12 && hour < 18) return "afternoon";
  return "evening";
}
