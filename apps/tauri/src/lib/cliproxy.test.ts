import { describe, expect, it } from "vitest";
import { cliproxyAccountState, cliproxyProblemText, cliproxyWindowLimits } from "./cliproxy";
import type { CliProxyAccount, CliProxyProblem } from "./agents";

function makeAccount(overrides: Partial<CliProxyAccount> = {}): CliProxyAccount {
  return {
    id: "acc-1",
    provider: "claude",
    agentKind: "claude",
    name: "dev@example.com",
    email: "dev@example.com",
    label: "dev",
    disabled: false,
    status: "active",
    statusMessage: null,
    unavailable: false,
    available: true,
    retryAt: null,
    succeeded: 12,
    failed: 1,
    windows: [],
    ...overrides,
  };
}

describe("cliproxy helpers", () => {
  it("provides non-empty copy for every CLIProxyProblem", () => {
    const problems: CliProxyProblem[] = [
      "noKey",
      "badAddress",
      "insecureAddress",
      "rejectedKey",
      "unreachable",
      "notAHub",
    ];
    for (const p of problems) {
      expect(cliproxyProblemText(p).trim().length).toBeGreaterThan(10);
    }
  });

  it("classifies account states (ready, disabled, holding, unavailable)", () => {
    const now = new Date("2026-11-26T12:00:00Z");
    expect(cliproxyAccountState(makeAccount(), now).tone).toBe("ready");
    expect(cliproxyAccountState(makeAccount({ disabled: true }), now).tone).toBe("muted");

    const holding = cliproxyAccountState(
      makeAccount({ unavailable: true, available: false, retryAt: "2026-11-26T12:15:00Z" }),
      now,
    );
    expect(holding.tone).toBe("warning");
    expect(holding.text).toContain("15");

    const unavail = cliproxyAccountState(makeAccount({ unavailable: true, available: false, retryAt: null }), now);
    expect(unavail.tone).toBe("warning");

    // Once retryAt has passed, the account is ready again.
    const recovered = cliproxyAccountState(
      makeAccount({ unavailable: true, available: true, retryAt: "2026-11-26T11:55:00Z" }),
      now,
    );
    expect(recovered.tone).toBe("ready");
  });

  it("maps and settles hub windows against now", () => {
    const now = new Date("2026-11-26T12:00:00Z");
    const limits = cliproxyWindowLimits(
      [
        { key: "five_hour", usedPercent: 64, resetsAt: "2026-11-26T15:00:00Z", durationSecs: 18000 },
        { key: "seven_day", usedPercent: 80, resetsAt: "2026-11-26T11:00:00Z", durationSecs: 604800 },
        { key: "other", usedPercent: 120, resetsAt: null, durationSecs: null },
      ],
      now,
    );
    expect(limits).toHaveLength(3);
    expect(limits[0].used).toBe(64);
    expect(limits[0].resetsAt).not.toBeNull();
    // Expired 7d window settles back to 0% with no reset time.
    expect(limits[1].used).toBe(0);
    expect(limits[1].resetsAt).toBeNull();
    // Out-of-range percentage clamps to 100.
    expect(limits[2].used).toBe(100);
  });
});
