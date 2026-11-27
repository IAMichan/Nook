import { describe, expect, it } from "vitest";
import { limitFallbacks, limitOptions, limitPicks, limitState, type LimitState } from "./limit-advisor";

const now = new Date("2026-11-27T12:00:00Z");
const state = (provider: string, profileId: string, usedFraction: number | null, resetAt: Date | null = null): LimitState => ({ provider, profileId, usedFraction, resetAt });
const current = { provider: "claude", profileId: "work" };

describe("limit-advisor (LimitAdvisor)", () => {
  it("offers nothing while the current account has room", () => {
    expect(limitOptions([state("claude", "work", 0.5), state("claude", "home", 0.1)], current, now)).toEqual([]);
  });

  it("puts the same agent first, then the least used, then unknown ones", () => {
    const reset = new Date(now.getTime() + 3600_000);
    const picks = limitOptions([
      state("claude", "work", 0.95, reset),
      state("codex", "main", 0.1),
      state("claude", "home", 0.4),
      state("claude", "full", 0.8),
      state("gemini", "g", null),
      state("claude", "new", null),
    ], current, now);
    expect(picks.map((p) => p.profileId)).toEqual(["home", "main", "new", "g"]);
    expect(picks[0]).toMatchObject({ sameAgent: true, usedFraction: 0.4, resumeIn: 3600 });
    expect(picks[1].sameAgent).toBe(false);
  });

  it("falls back to the least used that is not full", () => {
    const states = [state("claude", "work", 1), state("codex", "a", 0.85), state("claude", "b", 0.85), state("claude", "c", 1)];
    expect(limitOptions(states, current, now)).toEqual([]);
    expect(limitFallbacks(states, current, now).map((p) => p.profileId)).toEqual(["b", "a"]);
  });

  it("counts the current account as full", () => {
    expect(limitPicks([state("claude", "work", 0.2), state("claude", "home", 0.3)], current, now).map((p) => p.profileId)).toEqual(["home"]);
    expect(limitPicks([state("claude", "home", 0.3)], current, now).map((p) => p.profileId)).toEqual(["home"]);
  });

  it("reads an account's fullest window", () => {
    const soon = new Date(now.getTime() + 60_000);
    expect(limitState("codex", "a", [{ used: 30, resetsAt: null }, { used: 80, resetsAt: soon }])).toEqual({ provider: "codex", profileId: "a", usedFraction: 0.8, resetAt: soon });
    expect(limitState("codex", "a", []).usedFraction).toBeNull();
  });
});
