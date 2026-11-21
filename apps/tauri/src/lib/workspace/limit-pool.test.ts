import { describe, expect, it } from "vitest";
import {
  accountLimitsToPoolLimits,
  buildPoolSections,
  groupLimits,
  makePool,
  nextRefill,
  paceForLimit,
  paceOf,
  timeElapsed,
  usageTone,
  usedOf,
  weights,
  type Account,
  type AccountLimitInput,
  type Limit,
} from "./limit-pool";

const now = new Date(1_800_000_000_000);
const at = (s: number) => new Date(now.getTime() + s * 1000);
const fiveHours = 5 * 3600;
const week = 7 * 86_400;
const acc = (id: string, name: string, limits: Limit[], w: number | null = null): Account => ({ id, name, limits, sessionWeight: w, weeklyWeight: w });
const labels = { fiveHours: "5 hours", week: "Week", startsFirst: "Starts with your first message" };

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
    expect(paceForLimit(limit(60), now)).toBe("ahead");
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

  it("rounds used percentages and classifies usage tones", () => {
    expect(usedOf(38.5)).toBe(38);
    expect(usedOf(38.6)).toBe(39);
    expect(usageTone(74)).toBe("calm");
    expect(usageTone(75)).toBe("warning");
    expect(usageTone(89)).toBe("warning");
    expect(usageTone(90)).toBe("error");
  });

  it("converts Claude, Codex, and Antigravity limits and settles expired/unstarted windows", () => {
    const claude: AccountLimitInput = {
      profileId: "claude",
      kind: "claude",
      name: "Personal",
      email: "me@example.com",
      plan: "Max 5x",
      apiKey: false,
      usage: {
        fiveHour: { usedPercent: 42, resetsAt: at(3600).toISOString() },
        sevenDay: { usedPercent: 80, resetsAt: at(-60).toISOString() },
      },
      codex: null,
      antigravityLimits: [],
      antigravityNoLogin: false,
    };
    const claudeLimits = accountLimitsToPoolLimits(claude, labels, now);
    expect(claudeLimits).toHaveLength(2);
    expect(claudeLimits[0]).toMatchObject({ label: "5 hours", used: 42, note: null, duration: fiveHours });
    expect(claudeLimits[1]).toMatchObject({ label: "Week", used: 0, resetsAt: null, note: labels.startsFirst });

    const ag: AccountLimitInput = {
      profileId: "antigravity",
      kind: "antigravity",
      name: "Antigravity",
      email: null,
      plan: "",
      apiKey: false,
      usage: null,
      codex: null,
      antigravityLimits: [
        { label: "Gemini 3 Pro · 5 hours", percent: 0, resetsAt: at(fiveHours - 60).toISOString(), note: null, durationSecs: fiveHours },
        { label: "Gemini 3 Pro · Week", percent: 35, resetsAt: at(3 * 86_400).toISOString(), note: null, durationSecs: week },
      ],
      antigravityNoLogin: false,
    };
    const agLimits = accountLimitsToPoolLimits(ag, labels, now);
    expect(agLimits[0]).toMatchObject({ used: 0, resetsAt: null, note: labels.startsFirst });
    expect(agLimits[1]).toMatchObject({ used: 35, note: null });
    const grouped = groupLimits(agLimits);
    expect(grouped).toHaveLength(1);
    expect(grouped[0].name).toBe("Gemini 3 Pro");
    expect(grouped[0].limits.map((l) => l.window)).toEqual(["5 hours", "Week"]);
  });

  it("builds multi-agent pool sections with credits, notices, and hidden filter", () => {
    const accounts: AccountLimitInput[] = [
      {
        profileId: "codex-pro",
        kind: "codex",
        name: "Work",
        email: "work@example.com",
        plan: "Pro",
        apiKey: false,
        usage: null,
        codex: {
          fiveHour: { usedPercent: 100, resetsAt: at(1800).toISOString(), windowMinutes: 300 },
          weekly: { usedPercent: 50, resetsAt: at(3 * 86_400).toISOString(), windowMinutes: 10080 },
          resetCredits: { available: 2, nextExpiresAt: at(5 * 86_400).toISOString() },
        },
        antigravityLimits: [],
        antigravityNoLogin: false,
      },
      {
        profileId: "codex-plus",
        kind: "codex",
        name: "Personal",
        email: "me@example.com",
        plan: "Plus",
        apiKey: false,
        usage: null,
        codex: {
          fiveHour: { usedPercent: 0, resetsAt: at(3600).toISOString(), windowMinutes: 300 },
          weekly: { usedPercent: 0, resetsAt: at(5 * 86_400).toISOString(), windowMinutes: 10080 },
          resetCredits: null,
        },
        antigravityLimits: [],
        antigravityNoLogin: false,
      },
      {
        profileId: "gemini",
        kind: "gemini",
        name: "Gemini CLI",
        email: null,
        plan: "",
        apiKey: false,
        usage: null,
        codex: null,
        antigravityLimits: [],
        antigravityNoLogin: false,
      },
    ];

    const built = buildPoolSections(accounts, {
      now,
      labels,
      agentName: (k) => (k === "codex" ? "Codex" : "Gemini CLI"),
      unavailableReason: () => "No limits",
      formatNotice: (t, r) => `${t}: ${r}`,
    });
    expect(built.sections).toHaveLength(1);
    expect(built.sections[0].kind).toBe("codex");
    expect(built.sections[0].pool.windows[0].used).toBe(95);
    expect(built.sections[0].details["codex-pro"].credits).toBe(2);
    expect(built.notices).toEqual(["Gemini CLI: No limits"]);

    const filtered = buildPoolSections(accounts, {
      now,
      hidden: new Set(["codex"]),
      labels,
      agentName: (k) => (k === "codex" ? "Codex" : "Gemini CLI"),
      unavailableReason: () => "No limits",
      formatNotice: (t, r) => `${t}: ${r}`,
    });
    expect(filtered.sections).toHaveLength(0);
    expect(filtered.notices).toEqual(["Gemini CLI: No limits"]);
  });
});

