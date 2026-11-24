// The shared attention ranking (the Mac's `AttentionScorer`, `nook_core::services::attention::score`): what an item asks
// of you, how soon it is due, how long it waited and whether you can act on it here, plus how welcome its source, app and
// subject are from what you did before (`attention_weights`, at most ±10). Home and the empty Nook chat rank their
// items with it, and the tray's "Needs you" line takes its top need. Pure, so the order is tested.
import { invoke } from "@tauri-apps/api/core";
import type { InboxItem, Prioritizer } from "./inbox";

export type NeedsYou = "approval" | "question" | "reply" | "review" | "failure" | "info";

export interface AttentionItem {
  source: string;
  id: string;
  app?: string;
  subject?: string;
  needsYou: NeedsYou;
  /// When it is due or starts (ms since 1970).
  deadline?: number;
  /// Since when it waits on you (ms since 1970).
  since?: number;
  actionable?: boolean;
}

export type AttentionEvent = "shown" | "opened" | "dismissed" | "timedOut" | "snoozed" | "muted" | "answered" | "approved" | "denied";

const BASE: Record<NeedsYou, number> = { approval: 100, question: 90, failure: 70, reply: 60, review: 55, info: 30 };

export function attentionKey(item: Pick<AttentionItem, "source" | "app" | "subject">): string {
  return `${item.source.toLowerCase()}|${(item.app ?? "").trim().toLowerCase()}|${item.subject ?? ""}`;
}

/// How much one item counts; `weight` is how welcome it is, -1…1.
export function attentionScore(item: AttentionItem, weight: number, now: number): number {
  let score = BASE[item.needsYou];
  if (item.deadline !== undefined) {
    const ahead = (item.deadline - now) / 1000;
    if (ahead < 0) score += item.needsYou === "info" ? 0 : 20;
    else if (ahead <= 3600) score += 25;
    else if (ahead <= 3 * 3600) score += 15;
    else if (ahead <= 24 * 3600) score += 5;
  }
  if (item.since !== undefined) {
    const hours = Math.max(0, now - item.since) / 3_600_000;
    score += Math.min(10, Math.log2(1 + hours) * 2);
  }
  if (item.actionable !== false) score += 5;
  return score + 10 * weight;
}

/// Anything that carries an item, most important first; equal scores keep their order.
export function rankBy<T>(values: T[], item: (v: T) => AttentionItem, weights: Map<string, number>, now: number): T[] {
  return values
    .map((value, offset) => {
      const a = item(value);
      return { value, offset, score: attentionScore(a, weights.get(attentionKey(a)) ?? 0, now) };
    })
    .sort((a, b) => (a.score !== b.score ? b.score - a.score : a.offset - b.offset))
    .map((x) => x.value);
}

/// The first one that truly waits on you, if any.
export function topNeed<T>(values: T[], item: (v: T) => AttentionItem, weights: Map<string, number>, now: number): T | undefined {
  return rankBy(values.filter((v) => item(v).needsYou !== "info"), item, weights, now)[0];
}

/// What a Home item asks of you.
export function inboxAttention(i: InboxItem): AttentionItem {
  const at = Date.parse(i.at);
  const needsYou: NeedsYou =
    i.id.startsWith("approval:") ? "approval"
      : i.id.startsWith("question:") ? "question"
        : i.provider === "chats" && i.type === "action_required" ? "question"
          : i.provider === "owed" ? "reply"
            : i.id.startsWith("review:") ? "review"
              : i.id.startsWith("failing:") ? "failure"
                : "info";
  const dated = i.type === "reminder" && !Number.isNaN(at);
  return {
    source: i.provider === "owed" ? "chats" : i.source,
    id: i.id,
    app: i.sourceLabel?.toLowerCase() ?? "",
    subject: i.ref ?? "",
    needsYou,
    deadline: dated ? at : undefined,
    since: !dated && !Number.isNaN(at) ? at : undefined,
    actionable: i.actions.length > 0,
  };
}

/// Home's order from the shared ranking, with `weights` from what you did before.
export function attentionPrioritizer(weights: Map<string, number>): Prioritizer {
  return (items, now) => rankBy(items, inboxAttention, weights, now);
}

/// How welcome each item's source, app and subject are (`attention_weights`); empty outside the desktop app.
export async function loadWeights(items: AttentionItem[]): Promise<Map<string, number>> {
  const keys = [...new Map(items.map((i) => [attentionKey(i), { source: i.source, app: i.app ?? "", subject: i.subject ?? "" }])).entries()];
  if (!keys.length) return new Map();
  const values = await invoke<number[]>("attention_weights", { keys: keys.map(([, k]) => k) }).catch(() => [] as number[]);
  return new Map(keys.map(([key], n) => [key, values[n] ?? 0]));
}

/// Notes what you did with an item, for the next ranking (`attention_record`).
export function recordAttention(event: AttentionEvent, item: Pick<AttentionItem, "source" | "app" | "subject">) {
  invoke("attention_record", { event, source: item.source, app: item.app ?? "", subject: item.subject ?? "" }).catch(() => {});
}
