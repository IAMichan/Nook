// The "Coding agents" step of the first-run flow (`AgentReadiness` on the Mac): whether each agent is ready to start a
// session, and what its row offers. The recent folders that could become projects come from Rust
// (`workspace_project_candidates`, `core/src/workspace/readiness.rs`). No interface code, so tests use it on its own.
import type { AgentKind, AgentProfile, HistoryResult } from "./agents";

/** Where an agent stands, in the order the step sorts them: what needs you first. */
export type ReadinessState = "checking" | "connecting" | "signIn" | "missing" | "ready";
/** What the row offers: both go through the existing connect flow in a visible terminal; nothing installs on its own. */
export type ReadinessAction = "none" | "install" | "signIn";

/** The agents the step offers by name; any other agent that speaks ACP is added in Settings › Agents. */
export const ONBOARDING_AGENTS: AgentKind[] = ["claude", "codex", "gemini", "opencode", "cursor"];

export function classify(scanned: boolean, installed: boolean, signedIn: boolean, connecting: boolean): ReadinessState {
  if (connecting) return "connecting";
  if (installed) return signedIn ? "ready" : "signIn";
  // A sign-in without the program (the program was removed) still needs the program first.
  return scanned ? "missing" : "checking";
}

export function readinessAction(state: ReadinessState): ReadinessAction {
  if (state === "missing") return "install";
  if (state === "signIn") return "signIn";
  return "none";
}

/** Ready when at least one agent can start a session. */
export const anyReady = (states: ReadinessState[]) => states.includes("ready");

/** An agent's state from the session history scan and its accounts. */
export function agentState(kind: AgentKind, history: HistoryResult | null, profiles: AgentProfile[], connecting: boolean): ReadinessState {
  const installed = !!history && (history.installed.includes(kind) || !!history.executables[kind]);
  const signedIn = !!history && profiles.some((p) => p.kind === kind && !!history.accounts[p.id]);
  return classify(history !== null, installed, signedIn, connecting);
}
