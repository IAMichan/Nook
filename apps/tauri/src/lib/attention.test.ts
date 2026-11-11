import { describe, expect, it } from "vitest";
import type { InboxItem } from "./inbox";
import {
  allowedIn, catchUp, digestFor, digestItems, groupBySource, HISTORY_LIMIT, interrupts, parseFocus, pruneSnoozed, remember, snoozeUntil,
  splitByFocus, splitSnoozed, suggestFocus,
} from "./attention";

const now = new Date(2026, 10, 11, 14, 30).getTime(); // Wednesday 11 November 2026, 14:30 local
const item = (id: string, extra: Partial<InboxItem> = {}): InboxItem => ({
  id, provider: "test", source: "system", type: "update", title: id, at: new Date(now - 60_000).toISOString(), actions: [], ...extra,
});

describe("snooze", () => {
  it("comes back in an hour, tomorrow morning or next Monday morning", () => {
    expect(snoozeUntil("hour", new Date(now)).getTime()).toBe(now + 3_600_000);
    const tomorrow = snoozeUntil("tomorrow", new Date(now));
    expect([tomorrow.getDate(), tomorrow.getHours(), tomorrow.getMinutes()]).toEqual([12, 8, 0]);
    const week = snoozeUntil("week", new Date(now));
    expect([week.getDay(), week.getDate(), week.getHours()]).toEqual([1, 16, 8]);
    // On a Monday "next week" is a full week away, never today.
    expect(snoozeUntil("week", new Date(2026, 10, 16, 9)).getDate()).toBe(23);
  });

  it("hides snoozed items until they are due, and forgets ended snoozes", () => {
    const soon = new Date(now + 1000).toISOString();
    const past = new Date(now - 1000).toISOString();
    const { awake, asleep } = splitSnoozed([item("a"), item("b"), item("c")], { a: soon, b: past }, now);
    expect(asleep.map((i) => i.id)).toEqual(["a"]);
    expect(awake.map((i) => i.id)).toEqual(["b", "c"]);
    expect(pruneSnoozed({ a: soon, b: past, c: "x" }, now)).toEqual({ a: soon });
  });
});

describe("focus modes", () => {
  const action = item("action", { source: "agents", type: "action_required" });
  const chat = item("chat", { source: "messages", type: "missed", cared: true });
  const news = item("news", { source: "gamer_mode" });

  it("lets everything through by default and falls back from unknown modes", () => {
    expect([action, chat, news].every((i) => allowedIn("all", i))).toBe(true);
    expect(parseFocus("deep")).toBe("deep");
    expect(parseFocus("nonsense")).toBe("all");
    expect(parseFocus(null)).toBe("all");
  });

  it("filters by source and urgency, keeping held items", () => {
    expect(splitByFocus([action, chat, news], "work").held.map((i) => i.id)).toEqual(["news"]);
    const deep = splitByFocus([action, chat, news], "deep");
    expect(deep.allowed.map((i) => i.id)).toEqual(["action"]);
    expect(deep.held.map((i) => i.id)).toEqual(["chat", "news"]);
    expect(splitByFocus([action, chat, news], "off_hours").allowed.map((i) => i.id)).toEqual(["chat"]);
  });

  it("never interrupts while the system is in Do Not Disturb", () => {
    expect(interrupts("all", action, false)).toBe(true);
    expect(interrupts("all", action, true)).toBe(false);
    expect(interrupts("all", news, false)).toBe(false);
  });

  it("suggests a mode from the clock and the calendar", () => {
    expect(suggestFocus(new Date(now))).toBe("work");
    expect(suggestFocus(new Date(2026, 10, 11, 21))).toBe("off_hours");
    expect(suggestFocus(new Date(2026, 10, 14, 11))).toBe("off_hours");
    expect(suggestFocus(new Date(now), true)).toBe("deep");
  });
});

describe("grouping", () => {
  it("puts the source with the most pressing item first", () => {
    const groups = groupBySource([item("n1", { source: "notes" }), item("a1", { source: "agents", type: "action_required" }), item("n2", { source: "notes" })]);
    expect(groups.map((g) => [g.source, g.items.length])).toEqual([["agents", 1], ["notes", 2]]);
  });
});

describe("catch me up", () => {
  it("counts what came after you last looked, per source", () => {
    const since = new Date(now - 3_600_000).toISOString();
    const result = catchUp([
      item("old", { at: new Date(now - 7_200_000).toISOString() }),
      item("a", { source: "agents", type: "action_required", title: "Approve edit" }),
      item("m1", { source: "messages", at: new Date(now - 120_000).toISOString(), title: "Older message" }),
      item("m2", { source: "messages", title: "Newest message" }),
    ], since, now);
    expect(result.total).toBe(3);
    expect(result.needsYou).toBe(1);
    expect(result.sources.map((s) => [s.source, s.count])).toEqual([["agents", 1], ["messages", 2]]);
    expect(result.sources[1].latest).toBe("Newest message");
    expect(catchUp([item("x")], null, now).total).toBe(1);
  });
});

describe("history and digest", () => {
  it("remembers items once, newest first, within the limit", () => {
    const first = remember([], [item("a", { at: new Date(now - 5000).toISOString() }), item("b")]);
    expect(first.map((h) => h.id)).toEqual(["a", "b"]);
    expect(remember(first, [item("a")])).toBe(first);
    const many = remember([], Array.from({ length: HISTORY_LIMIT + 20 }, (_, i) => item(`i${i}`)));
    expect(many).toHaveLength(HISTORY_LIMIT);
  });

  it("offers the morning brief before noon and the evening wrap-up from five", () => {
    expect([4, 5, 11, 12, 16, 17, 23].map(digestFor)).toEqual([null, "morning", "morning", null, null, "evening", "evening"]);
    const open = [item("a", { type: "action_required" }), item("b")];
    expect(digestItems("morning", open, null, now).map((i) => i.id)).toEqual(["a"]);
    expect(digestItems("evening", open, new Date(now - 3_600_000).toISOString(), now)).toHaveLength(2);
  });
});
