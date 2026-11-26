// Pure state and helpers for `SetupCheckStep`, mirroring Mac's `SetupCheckState` (`SettingsStyle.swift`).
// Kept framework-free so setup flows and tests can compute the check step's state deterministically.

import type { Health } from "../../lib/connectors";

export type SetupCheckState =
  | { kind: "idle" }
  | { kind: "checking" }
  | { kind: "passed"; message: string }
  | { kind: "failed"; message: string };

export const setupCheck = {
  idle: (): SetupCheckState => ({ kind: "idle" }),
  checking: (): SetupCheckState => ({ kind: "checking" }),
  passed: (message: string): SetupCheckState => ({ kind: "passed", message }),
  failed: (message: string): SetupCheckState => ({ kind: "failed", message }),
};

export function isSetupCheckPassed(state: SetupCheckState): boolean {
  return state.kind === "passed";
}

/** Map a connector's `Health` status to the standard `SetupCheckState`. */
export function setupCheckFromHealth(
  health: Health,
  messages: { passed: string; failed: string },
): SetupCheckState {
  switch (health) {
    case "notLinked":
    case "off":
      return { kind: "idle" };
    case "busy":
      return { kind: "checking" };
    case "working":
    case "needsYou":
      return { kind: "passed", message: messages.passed };
    case "broken":
      return { kind: "failed", message: messages.failed };
  }
}
