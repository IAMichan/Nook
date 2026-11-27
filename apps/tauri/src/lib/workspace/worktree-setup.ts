// Pure helpers for worktree setup checklist display (`WorktreeSetupProgress` on macOS, AG-94).
import type { SetupStep, StepState, WorktreeSetupProgress } from "./api";

export const SETUP_STEPS: readonly SetupStep[] = ["fetchBase", "checkOut", "runSetup", "startAgent"];

export function setupStepState(progress: WorktreeSetupProgress, step: SetupStep): StepState {
  return progress.states[step] ?? { kind: "pending" };
}

export function setupFailure(progress: WorktreeSetupProgress): { step: SetupStep; message: string } | null {
  for (const step of SETUP_STEPS) {
    const st = setupStepState(progress, step);
    if (st.kind === "failed") return { step, message: st.message };
  }
  return null;
}

/** Matches macOS `WorktreeSetupProgress.duration(_:)`: `"774ms"`, `"1.4s"`, `"2m 05s"`. */
export function formatSetupDuration(seconds: number): string {
  const clamped = Math.max(0, Number.isFinite(seconds) ? seconds : 0);
  if (clamped < 1) return `${Math.round(clamped * 1000)}ms`;
  if (clamped < 60) return `${clamped.toFixed(1)}s`;
  const whole = Math.round(clamped);
  const mins = Math.floor(whole / 60);
  const secs = String(whole % 60).padStart(2, "0");
  return `${mins}m ${secs}s`;
}
