import { describe, expect, it } from "vitest";
import { CALM_SHOWN, daypart, FORGET_AFTER, pruneDismissed, rank, SHOWN, tier, type InboxItem } from "./inbox";
import { DEFAULT_ESSENTIALS, essentials, features, moveTo } from "./features";

const now = Date.parse("2026-10-31T12:00:00Z");
const item = (id: string, extra: Partial<InboxItem> = {}): InboxItem => ({
  id, provider: "test", source: "system", type: "update", title: id, at: new Date(now - 60_000).toISOString(), actions: [], ...extra,
});

describe("inbox ranking", () => {
  it("puts what needs you first, then what you care about, then what you missed", () => {
    const { shown } = rank([
      item("insight", { type: "insight" }),
      item("missed", { type: "missed" }),
      item("cared", { type: "reminder", cared: true }),
      item("action", { type: "action_required" }),
      item("reminder", { type: "reminder" }),
    ], {}, now);
    expect(shown.map((i) => i.id)).toEqual(["action", "cared", "missed", "reminder", "insight"]);
    expect(tier(item("x", { type: "update", weight: 1 }))).toBe(3);
    expect(tier(item("x", { type: "update" }))).toBe(4);
  });

  it("orders reminders by how soon they are due and the rest newest first", () => {
    const soon = item("soon", { type: "reminder", at: new Date(now + 3_600_000).toISOString() });
    const later = item("later", { type: "reminder", at: new Date(now + 20 * 3_600_000).toISOString() });
    const old = item("old", { type: "missed", at: new Date(now - 7_200_000).toISOString() });
    const fresh = item("fresh", { type: "missed", at: new Date(now - 60_000).toISOString() });
    expect(rank([later, old, soon, fresh], {}, now).shown.map((i) => i.id)).toEqual(["fresh", "old", "soon", "later"]);
    const urgent = item("urgent", { type: "reminder", weight: 2, at: later.at });
    expect(rank([soon, urgent], {}, now).shown[0].id).toBe("urgent");
  });

  it("leaves out dismissed items and duplicates", () => {
    const { shown, rest } = rank([item("a"), item("b"), item("a")], { b: new Date(now).toISOString() }, now);
    expect(shown.map((i) => i.id)).toEqual(["a"]);
    expect(rest).toEqual([]);
  });

  it("never lets calm news crowd out the inbox", () => {
    const calm = Array.from({ length: 6 }, (_, i) => item(`calm${i}`));
    const { shown, rest } = rank([...calm, item("action", { type: "action_required" })], {}, now);
    expect(shown.map((i) => i.id)[0]).toBe("action");
    expect(shown.filter((i) => tier(i) === 4)).toHaveLength(CALM_SHOWN);
    expect(shown.length + rest.length).toBe(7);
    const busy = Array.from({ length: 8 }, (_, i) => item(`a${i}`, { type: "action_required" }));
    expect(rank(busy, {}, now).shown).toHaveLength(SHOWN);
  });

  it("takes a different order from a prioritizer", () => {
    const reversed = rank([item("a", { type: "action_required" }), item("b")], {}, now, (items) => [...items].reverse());
    expect(reversed.shown.map((i) => i.id)).toEqual(["b", "a"]);
  });

  it("forgets old dismissals", () => {
    const kept = new Date(now - 1000).toISOString();
    const old = new Date(now - FORGET_AFTER - 1000).toISOString();
    expect(pruneDismissed({ kept, old, broken: "x" }, now)).toEqual({ kept });
  });

  it("greets by the time of day", () => {
    expect([4, 5, 11, 12, 17, 18, 23].map(daypart)).toEqual(["evening", "morning", "morning", "afternoon", "afternoon", "evening", "evening"]);
  });
});

describe("home essentials", () => {
  it("shows the defaults until you choose, in your order, without unknown or missing features", () => {
    expect(essentials(null, features).map((f) => f.id)).toEqual(DEFAULT_ESSENTIALS);
    expect(essentials(["games", "gone", "chat", "games"], features).map((f) => f.id)).toEqual(["games", "chat"]);
    expect(essentials(["agents", "chat"], features.filter((f) => f.id !== "agents")).map((f) => f.id)).toEqual(["chat"]);
    expect(essentials([], features)).toEqual([]);
  });

  it("gives every feature a unique id", () => {
    expect(new Set(features.map((f) => f.id)).size).toBe(features.length);
  });

  it("moves a feature to a new place", () => {
    expect(moveTo(["a", "b", "c"], "c", 0)).toEqual(["c", "a", "b"]);
    expect(moveTo(["a", "b", "c"], "a", 5)).toEqual(["b", "c", "a"]);
    expect(moveTo(["a", "b", "c"], "b", -1)).toEqual(["b", "a", "c"]);
    expect(moveTo(["a"], "x", 0)).toEqual(["a"]);
  });
});
