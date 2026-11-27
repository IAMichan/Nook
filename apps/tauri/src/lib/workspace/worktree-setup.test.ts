import { describe, expect, it } from "vitest";
import { formatSetupDuration, SETUP_STEPS, setupFailure, setupStepState } from "./worktree-setup";
import type { WorktreeSetupProgress } from "./api";

describe("worktree-setup helpers", () => {
  it("formats durations identically to macOS WorktreeSetupProgress.duration", () => {
    expect(formatSetupDuration(0)).toBe("0ms");
    expect(formatSetupDuration(-3)).toBe("0ms");
    expect(formatSetupDuration(0.774)).toBe("774ms");
    expect(formatSetupDuration(1.42)).toBe("1.4s");
    expect(formatSetupDuration(59.9)).toBe("59.9s");
    expect(formatSetupDuration(125)).toBe("2m 05s");
  });

  it("extracts step states and first failure in step order", () => {
    const progress: WorktreeSetupProgress = {
      startedAt: "2026-11-26T12:00:00Z",
      states: {
        fetchBase: { kind: "skipped" },
        checkOut: { kind: "done", seconds: 1.2 },
        runSetup: { kind: "failed", message: "exit code 1" },
        startAgent: { kind: "pending" },
      },
      notes: [],
    };
    expect(SETUP_STEPS).toEqual(["fetchBase", "checkOut", "runSetup", "startAgent"]);
    expect(setupStepState(progress, "fetchBase")).toEqual({ kind: "skipped" });
    expect(setupFailure(progress)).toEqual({ step: "runSetup", message: "exit code 1" });
  });

  it("returns null failure when all steps are pending, running, skipped, or done", () => {
    const progress: WorktreeSetupProgress = {
      startedAt: "2026-11-26T12:00:00Z",
      states: {
        fetchBase: { kind: "done", seconds: 0.5 },
        checkOut: { kind: "running", since: "2026-11-26T12:00:01Z" },
      },
      notes: [],
    };
    expect(setupFailure(progress)).toBeNull();
    expect(setupStepState(progress, "startAgent")).toEqual({ kind: "pending" });
  });
});
