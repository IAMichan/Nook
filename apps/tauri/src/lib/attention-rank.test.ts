import { describe, expect, it } from "vitest";
import { attentionScore, inboxAttention, rankBy, topNeed, attentionKey, type AttentionItem } from "./attention-rank";
import type { InboxItem } from "./inbox";

const now = Date.parse("2026-11-22T12:00:00Z");
const item = (id: string, needsYou: AttentionItem["needsYou"], extra: Partial<AttentionItem> = {}): AttentionItem => ({ source: "agents", id, needsYou, ...extra });
const none = new Map<string, number>();

describe("attention ranking (the Mac's AttentionScorer)", () => {
  it("puts needs in the Mac's order", () => {
    const ranked = rankBy([item("i", "info"), item("r", "reply"), item("a", "approval"), item("q", "question")], (x) => x, none, now);
    expect(ranked.map((x) => x.id)).toEqual(["a", "q", "r", "i"]);
  });

  it("lifts what is due soon, overdue and waited long, as the Rust scorer does", () => {
    expect(attentionScore(item("s", "info", { deadline: now + 30 * 60_000 }), 0, now)).toBe(60);
    expect(attentionScore(item("l", "review", { deadline: now - 5 * 60_000 }), 0, now)).toBe(80);
    expect(attentionScore(item("w", "reply", { since: now - 1000 * 3_600_000 }), 0, now)).toBe(75);
    expect(attentionScore(item("x", "info", { actionable: false }), -1, now)).toBe(20);
  });

  it("follows what you did before and leaves info out of the top need", () => {
    const slack = item("s", "reply", { source: "chats", app: "slack" });
    const wa = item("w", "reply", { source: "chats", app: "whatsapp" });
    const weights = new Map([[attentionKey(slack), -0.7], [attentionKey(wa), 0.3]]);
    expect(rankBy([slack, wa], (x) => x, weights, now)[0].id).toBe("w");
    expect(topNeed([item("i", "info")], (x) => x, none, now)).toBeUndefined();
  });

  it("reads what a Home item asks of you", () => {
    const base: InboxItem = { id: "approval:1", provider: "agents", source: "agents", type: "action_required", title: "", at: new Date(now).toISOString(), actions: [{ id: "x", label: "x" }] };
    expect(inboxAttention(base).needsYou).toBe("approval");
    expect(inboxAttention({ ...base, id: "owed:t:1", provider: "owed", source: "messages", sourceLabel: "Telegram", ref: "t" })).toMatchObject({ needsYou: "reply", source: "chats", app: "telegram", subject: "t" });
    const reminder = inboxAttention({ ...base, id: "loop:1", provider: "tasks", source: "tasks", type: "reminder" });
    expect(reminder.needsYou).toBe("info");
    expect(reminder.deadline).toBe(now);
  });
});
