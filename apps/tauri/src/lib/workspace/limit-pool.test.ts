import { describe, expect, it } from "vitest";
import { makePool, nextRefill, paceOf, timeElapsed, weights, type Account, type Limit } from "./limit-pool";

const now = new Date(1_800_000_000_000);
const at = (s: number) => new Date(now.getTime() + s * 1000);
const fiveHours = 5 * 3600;
const week = 7 * 86_400;
const acc = (id: string, name: string, limits: Limit[], w: number | null = null): Account => ({ id, name, limits, sessionWeight: w, weeklyWeight: w });

describe("limit pool (LimitPoolTests)", () => {
  it("has no pool without limits, and one account is a pool of one", () => {
    expect(makePool([acc("a", "a", [])], now)).toBeNull();
    const pool = makePool([acc("a", "a", [{ label: "5 hours", used: 38, resetsAt: at(3600), duration: fiveHours }])], now)!;
    expect(pool.windows.map((w) => w.used)).toEqual([38]);
  });

  it("averages, keeps columns and hands back the refill", () => {
    const work = acc("w", "Work", [{ label: "5 hours", used: 80, resetsAt: at(600), duration: null }, { label: "Week", used: 50, resetsAt: at(86_400), duration: null }]);
    const personal = acc("p", "Personal", [{ label: "5 hours", used: 20, resetsAt: at(7200), duration: null }]);
    const pool = makePool([personal, work], now)!;
    expect(pool.windows.map((w) => w.label)).toEqual(["5 hours", "Week"]);
    expect(pool.windows[0].columns.map((c) => c.name)).toEqual(["Work", "Personal"]);
    expect(pool.windows[0].used).toBe(50);
    expect(pool.windows[1].columns[1].limit).toBeNull();
    expect(pool.windows[1].used).toBe(50);
    expect(nextRefill(pool.windows[0])).toEqual({ accountId: "w", at: at(600), restores: 40 });
  });

  it("compares spending with the clock", () => {
    const limit = (used: number): Limit => ({ label: "5 hours", used, resetsAt: at(3 * 3600), duration: fiveHours });
    expect(makePool([acc("a", "a", [limit(60)])], now)!.windows[0].pace).toBe("ahead");
    expect(paceOf(40, 0.4)).toBe("on");
    expect(paceOf(10, 0.4)).toBe("under");
    expect(timeElapsed(limit(0), now)).toBe(40);
  });

  it("empties the session window while the week is spent", () => {
    const pool = makePool([acc("a", "a", [
      { label: "5 hours", used: 20, resetsAt: at(3600), duration: fiveHours },
      { label: "Week", used: 100, resetsAt: at(86_400), duration: week },
    ])], now)!;
    const session = pool.windows.find((w) => w.kind === "session")!;
    expect(session.used).toBe(100);
    expect(session.pace).toBeNull();
    expect(session.columns[0].limit?.resetsAt).toEqual(at(86_400));
    expect(session.columns[0].refill).toBe(100);
  });

  it("weighs accounts by plan size", () => {
    expect(weights("claude", "Max 20x")).toEqual({ session: 20, weekly: null });
    expect(weights("codex", "pro")).toEqual({ session: 20, weekly: 20 });
    const pool = makePool([acc("big", "Big", [{ label: "5 hours", used: 100, resetsAt: at(60), duration: fiveHours }], 20), acc("small", "Small", [{ label: "5 hours", used: 0, resetsAt: at(120), duration: fiveHours }], 1)], now)!;
    expect(pool.windows[0].used).toBe(95);
  });
});
