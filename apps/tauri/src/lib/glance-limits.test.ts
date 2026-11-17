import { describe, expect, it } from "vitest";
import { glanceLimits, tone } from "./glance-limits";
import type { AgentProfile } from "./agents";

const now = Date.parse("2026-11-17T12:00:00Z");
const later = "2026-11-17T15:00:00Z";
const past = "2026-11-17T09:00:00Z";
const profile = (id: string, label: string): AgentProfile => ({ id, kind: "claude", label } as AgentProfile);

describe("plan limits on the empty chat", () => {
  it("shows each account's fullest window, a reset window as empty", () => {
    const limits = glanceLimits(
      null,
      {
        work: { fiveHour: { usedPercent: 40, resetsAt: later }, sevenDay: { usedPercent: 81, resetsAt: later }, updated: "" },
        home: { fiveHour: { usedPercent: 95, resetsAt: past }, sevenDay: { usedPercent: 12, resetsAt: later }, updated: "" },
      },
      [profile("work", "Work"), profile("home", "Home")],
      now,
    );
    expect(limits).toEqual([
      { id: "work", name: "Claude · Work", window: "week", used: 81 },
      { id: "home", name: "Claude · Home", window: "week", used: 12 },
    ]);
  });

  it("falls back to the main account and says nothing without data", () => {
    const main = { fiveHour: { usedPercent: 33.4, resetsAt: later }, sevenDay: null, updated: "" };
    expect(glanceLimits(main, {}, [], now)).toEqual([{ id: "claude", name: "Claude", window: "5h", used: 33 }]);
    expect(glanceLimits(null, {}, [], now)).toEqual([]);
  });

  it("uses the Mac's tones", () => {
    expect([tone(74), tone(75), tone(90)]).toEqual(["calm", "warning", "error"]);
  });
});
