// The cards an agent puts in its own timeline through the bridge (`session_suggest`, `render_page`): reading them from
// their event and what choosing on a suggestion does. The rules match `core/src/workspace/session_cards.rs`.
import { invoke } from "@tauri-apps/api/core";
import type { IsolationMode, NewRunConfig, PermissionPolicy, RunEvent, RunProvider, WorkspaceRun } from "./api";

export const SUGGESTION_TOOL = "session_suggestion";
export const PAGE_TOOL = "render_page";

export interface SessionSuggestion {
  title: string;
  prompt: string;
  summary: string;
  agent: string;
  worktree: boolean | null;
}

export type SuggestionChoice = "start" | "here" | "options" | "dismiss";

/** The suggestion an event carries; null for any other event. */
export function suggestionOf(event: RunEvent): SessionSuggestion | null {
  if (event.kind !== "system" || event.tool !== SUGGESTION_TOOL || !event.detail) return null;
  try {
    const raw = JSON.parse(event.detail) as Partial<SessionSuggestion>;
    if (typeof raw.prompt !== "string" || typeof raw.title !== "string") return null;
    return { title: raw.title, prompt: raw.prompt, summary: raw.summary ?? "", agent: raw.agent ?? "", worktree: raw.worktree ?? null };
  } catch {
    return null;
  }
}

/** The agent a suggestion names by id or name, else null (then the session's own agent). */
export function namedProvider(name: string, providers: { provider: RunProvider; name: string }[]): RunProvider | null {
  const wanted = name.trim().toLowerCase();
  if (!wanted) return null;
  return providers.find((p) => p.provider === wanted || p.name.toLowerCase() === wanted)?.provider ?? null;
}

/** The page's height in the timeline: what the agent asked, 80 to 1200, 360 without it. */
export function pageHeight(event: RunEvent): number {
  const h = Number(event.output);
  return Number.isFinite(h) && h > 0 ? Math.min(1200, Math.max(80, Math.round(h))) : 360;
}

/** The new session a suggestion starts beside `run`: its agent (or the run's), the run's project, a worktree of its
    own when asked, and Ask as its rights when the agent offers it. */
export function suggestedConfig(
  s: SessionSuggestion,
  run: WorkspaceRun,
  provider: RunProvider,
  policies: PermissionPolicy[],
  defaults: { models: Record<string, string>; profiles: Record<string, string> },
): NewRunConfig {
  const same = provider === run.provider;
  const isolation: IsolationMode = s.worktree === true ? "worktree" : s.worktree === false ? "folder" : run.isolation;
  return {
    title: s.title,
    task: s.prompt,
    provider,
    profileId: same ? run.profileId : (defaults.profiles[provider] ?? provider),
    model: same ? run.model : (defaults.models[provider] ?? ""),
    mode: "agent",
    permission: policies.includes("ask") ? "ask" : (policies[0] ?? "ask"),
    isolation,
    projectPath: run.projectPath || run.workingDirectory,
    baseBranch: isolation === "worktree" ? (run.baseBranch ?? "") : "",
    branchName: "",
    worktreeRoot: "",
    instructions: "",
    effort: null,
  };
}

export const sessionCardsApi = {
  chosen: (run: string, event: string, choice: SuggestionChoice, session?: string) =>
    invoke<void>("workspace_suggestion_chosen", { run: run.replace(/^run:/, ""), event, choice, session: session ?? null }),
  pageHtml: (run: string, event: string) => invoke<string>("workspace_page_html", { run: run.replace(/^run:/, ""), event }),
};
