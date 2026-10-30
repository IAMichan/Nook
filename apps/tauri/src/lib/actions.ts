// GitHub Actions under Agents › Actions (`ActionsPanel` on the Mac): the workflow runs of one repository, so a CI run
// or a promote can be followed without a pull request in between. The API, the repository picker's list, and the words
// the views use.
import { invoke } from "@tauri-apps/api/core";
import type { AccountPullRequests } from "./connectors";
import { tr } from "./i18n.svelte";
import { ciClock, ciElapsed, type CheckOutcome, type PullRequestCheck } from "./pulls";

export type RunOutcome = CheckOutcome | "cancelled";
export type RunStatusFilter = "all" | "running" | "failed";
export type RunAction = "rerun" | "rerunFailed" | "cancel";

export interface ActionsRepo {
  name: string;
  /// The account that listed it; null for one typed in or taken from a pull request.
  account: string | null;
  pushed: string | null;
}

export interface ActionsRepos {
  /// False while no GitHub account is connected.
  available: boolean;
  repos: ActionsRepo[];
}

export interface Workflow {
  id: number;
  name: string;
  path: string;
}

export interface WorkflowRun {
  id: number;
  workflowId: number;
  workflow: string;
  title: string;
  number: number;
  attempt: number;
  branch: string | null;
  sha: string;
  /// push, pull_request, workflow_dispatch, release, schedule…
  event: string;
  actor: string;
  status: string;
  conclusion: string | null;
  outcome: RunOutcome;
  running: boolean;
  created: string | null;
  started: string | null;
  finished: string | null;
  url: string | null;
}

export interface RunJob {
  id: number;
  name: string;
  outcome: RunOutcome;
  detail: string;
  running: boolean;
  started: string | null;
  finished: string | null;
  url: string | null;
}

export interface ActionRuns {
  /// The account that could read the repository; the job logs are read with it too.
  account: string;
  runs: WorkflowRun[];
}

export interface RunDetail {
  account: string;
  run: WorkflowRun;
  jobs: RunJob[];
}

export const actionsApi = {
  repos: () => invoke<ActionsRepos>("github_actions_repos"),
  workflows: (account: string | null, repo: string) => invoke<Workflow[]>("github_actions_workflows", { account, repo }),
  runs: (account: string | null, repo: string, workflow: number | null, status: RunStatusFilter) =>
    invoke<ActionRuns>("github_actions_runs", { account, repo, workflow, status }),
  run: (account: string | null, repo: string, run: number) => invoke<RunDetail>("github_actions_run", { account, repo, run }),
  /// Only after a click in the run's view; written to the action log.
  act: (account: string | null, repo: string, run: number, action: RunAction) =>
    invoke<void>("github_actions_run_action", { account, repo, run, action }),
};

/// "owner/name", the same rule as `is_repository` in the core; a pasted GitHub link works too.
export function parseRepo(text: string): string | null {
  let t = text.trim().replace(/\.git$/, "").replace(/\/+$/, "");
  const link = t.match(/^(?:https?:\/\/)?(?:www\.)?github\.com\/([^/]+\/[^/?#]+)/i);
  if (link) t = link[1];
  return /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(t) && !t.includes("..") ? t : null;
}

/// The picker's list: the repositories pushed to lately first, then the ones of the pull requests Nook already shows,
/// then the ones typed in before; each once, whatever its case.
export function candidateRepos(pushed: ActionsRepo[], pulls: AccountPullRequests[], typed: string[]): ActionsRepo[] {
  const result: ActionsRepo[] = [];
  const add = (repo: ActionsRepo) => {
    if (!result.some((r) => r.name.toLowerCase() === repo.name.toLowerCase())) result.push(repo);
  };
  pushed.forEach(add);
  for (const a of pulls) {
    for (const item of [...a.mine, ...a.reviews, ...a.watched]) add({ name: item.repo, account: a.id, pushed: null });
  }
  for (const name of typed) add({ name, account: null, pushed: null });
  return result;
}

/// Whether a run still changes: queued, waiting or running.
export const isLive = (run: { status: string }) => run.status !== "completed";

/// How long a run took, or has been running so far: "3:12". Null while it is queued.
export function runClock(run: { started: string | null; finished: string | null }, now: number = Date.now()): string | null {
  const seconds = ciElapsed(run.started, run.finished, now);
  return seconds === null ? null : ciClock(seconds);
}

/// A job as the check `CheckLog` opens: its page link carries the job id, and a cancelled job reads as one.
export function jobCheck(job: RunJob): PullRequestCheck {
  return {
    name: job.name,
    outcome: job.outcome === "cancelled" ? "failing" : job.outcome,
    detail: job.detail,
    url: job.url,
    checkRun: true,
    running: job.running,
    started: job.started,
    finished: job.finished,
  };
}

// Words

export const statusFilterName = (s: RunStatusFilter) =>
  s === "running" ? tr("Bezig", "Running") : s === "failed" ? tr("Mislukt", "Failed") : tr("Alle", "All");

/// The run's state in a word, for its header: "Geslaagd", "Bezig", "In de wachtrij"…
export function outcomeName(run: { outcome: RunOutcome; running: boolean; status: string }): string {
  switch (run.outcome) {
    case "passing": return tr("Geslaagd", "Succeeded");
    case "failing": return tr("Mislukt", "Failed");
    case "cancelled": return tr("Geannuleerd", "Cancelled");
    case "skipped": return tr("Overgeslagen", "Skipped");
    default:
      if (run.running) return tr("Bezig", "Running");
      return run.status === "waiting" ? tr("Wacht op goedkeuring", "Waiting for approval") : tr("In de wachtrij", "Queued");
  }
}

/// What started a run, in words people use; an event Nook does not know keeps GitHub's name.
export function eventName(event: string): string {
  const names: Record<string, [string, string]> = {
    push: ["push", "push"],
    pull_request: ["pull request", "pull request"],
    pull_request_target: ["pull request", "pull request"],
    workflow_dispatch: ["handmatig", "manual"],
    release: ["release", "release"],
    schedule: ["gepland", "scheduled"],
    merge_group: ["merge-wachtrij", "merge queue"],
    workflow_run: ["na workflow", "after workflow"],
    repository_dispatch: ["dispatch", "dispatch"],
  };
  const name = names[event];
  return name ? tr(name[0], name[1]) : event.replaceAll("_", " ");
}
