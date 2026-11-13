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
  /// The workflow file it ran from (".github/workflows/ci.yml"); empty when GitHub gave none.
  path: string;
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

/// Why a finished run has no jobs (`NoJobs` in the core). GitHub keeps no log for such a run, so this is what the run
/// view shows in place of its jobs.
export type NoJobs =
  | { kind: "replaced"; id: number; number: number; url: string | null }
  | { kind: "cancelled" }
  | { kind: "workflowError"; path: string; file: string | null }
  | { kind: "skipped" }
  | { kind: "approval" }
  | { kind: "empty" };

export interface RunDetail {
  account: string;
  run: WorkflowRun;
  jobs: RunJob[];
  noJobs: NoJobs | null;
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

/// The repositories on the page's tab bar after opening `name` (`ActionsRepoBar` on the Mac): a tab that is there keeps
/// its place, as tabs do; a new one goes first, and the last one falls off past `limit`.
export function openTab(name: string, tabs: string[], limit = 8): string[] {
  if (tabs.some((t) => t.toLowerCase() === name.toLowerCase())) return tabs;
  return [name, ...tabs].slice(0, limit);
}

/// The tab next to the open one (`offset` -1 or 1), going round; null with fewer than two tabs.
export function neighborTab(tabs: string[], current: string | null, offset: number): string | null {
  const index = tabs.findIndex((t) => t.toLowerCase() === (current ?? "").toLowerCase());
  if (tabs.length < 2 || index < 0) return null;
  return tabs[(index + offset + tabs.length) % tabs.length];
}

/// The repositories that match what you type in the picker: those whose owner or name starts with it first, then
/// those that contain it anywhere, each keeping its place. All of them for an empty search.
export function matchRepos<T extends { name: string }>(query: string, repos: T[]): T[] {
  const q = query.trim().toLowerCase();
  if (!q) return repos;
  const hits = repos.filter((r) => r.name.toLowerCase().includes(q));
  const named = hits.filter((r) => r.name.toLowerCase().split("/").some((part) => part.startsWith(q)));
  return [...named, ...hits.filter((r) => !named.includes(r))];
}

/// How a repository's Actions stand at a glance, for its tab: how many runs still run or wait, how many workflows'
/// newest finished run failed, and the mark that sums it up.
export interface RepoStatus {
  outcome: RunOutcome;
  running: boolean;
  active: number;
  failing: number;
}

/// Null for a repository without runs: its tab shows no mark. `runs` are newest first, as GitHub gives them.
export function repoStatus(runs: WorkflowRun[]): RepoStatus | null {
  if (!runs.length) return null;
  const active = runs.filter(isLive).length;
  const newest = new Map<number, WorkflowRun>();
  for (const run of runs) if (!isLive(run) && !newest.has(run.workflowId)) newest.set(run.workflowId, run);
  const failing = [...newest.values()].filter((r) => r.outcome === "failing").length;
  const outcome: RunOutcome = active ? "pending" : failing ? "failing" : runs[0].outcome;
  return { outcome, running: runs.some((r) => r.running), active, failing };
}

/// The newest run of each workflow, by workflow id, for the mark on its chip.
export function latestPerWorkflow(runs: WorkflowRun[]): Map<number, WorkflowRun> {
  const result = new Map<number, WorkflowRun>();
  for (const run of runs) if (!result.has(run.workflowId)) result.set(run.workflowId, run);
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

/// Why a run has no jobs, in a sentence, with the page that says more: the run that replaced it, or the workflow file
/// that kept it from starting.
export function noJobsReason(reason: NoJobs, run: Pick<WorkflowRun, "workflow" | "branch">): { text: string; link: { label: string; url: string } | null } {
  const noLog = tr("GitHub bewaart geen log voor een run zonder jobs.", "GitHub keeps no log for a run without jobs.");
  switch (reason.kind) {
    case "replaced": {
      const text = run.branch
        ? tr(
            "Geannuleerd voordat er een job begon: een nieuwere run van {workflow} op {branch} (#{number}) nam zijn plaats in. {noLog}",
            "Cancelled before any job started: a newer run of {workflow} on {branch} (#{number}) took its place. {noLog}",
            { workflow: run.workflow, branch: run.branch, number: reason.number, noLog },
          )
        : tr(
            "Geannuleerd voordat er een job begon: een nieuwere run van {workflow} (#{number}) nam zijn plaats in. {noLog}",
            "Cancelled before any job started: a newer run of {workflow} (#{number}) took its place. {noLog}",
            { workflow: run.workflow, number: reason.number, noLog },
          );
      return {
        text,
        link: reason.url ? { label: tr("Open #{number}", "Open #{number}", { number: reason.number }), url: reason.url } : null,
      };
    }
    case "cancelled":
      return {
        text: tr(
          "Geannuleerd voordat er een job begon, door iemand of door een andere workflow. {noLog}",
          "Cancelled before any job started, by someone or by another workflow. {noLog}",
          { noLog },
        ),
        link: null,
      };
    case "workflowError": {
      const file = reason.path || tr("het workflowbestand", "the workflow file");
      return {
        text: tr(
          "GitHub kon de workflow niet starten, bijna altijd door een fout in {file}. De precieze fout staat alleen op de pagina van de run op GitHub.",
          "GitHub could not start the workflow, nearly always because of an error in {file}. The exact error is only on the run's page on GitHub.",
          { file },
        ),
        link: reason.file ? { label: tr("Workflowbestand", "Workflow file"), url: reason.file } : null,
      };
    }
    case "skipped":
      return { text: tr("Elke job werd overgeslagen door zijn voorwaarde.", "Every job was skipped by its condition."), link: null };
    case "approval":
      return { text: tr("De run wacht op goedkeuring voordat er een job begint.", "The run waits for approval before any job starts."), link: null };
    default:
      return { text: tr("Deze run heeft geen jobs. {noLog}", "This run has no jobs. {noLog}", { noLog }), link: null };
  }
}

/// What started a run, in words people use; an event Nook does not know keeps GitHub's name.
export function eventName(event: string): string {
  switch (event) {
    case "push": return "push";
    case "pull_request":
    case "pull_request_target": return "pull request";
    case "workflow_dispatch": return tr("handmatig", "manual");
    case "release": return "release";
    case "schedule": return tr("gepland", "scheduled");
    case "merge_group": return tr("merge-wachtrij", "merge queue");
    case "workflow_run": return tr("na workflow", "after workflow");
    case "repository_dispatch": return "dispatch";
    default: return event.replaceAll("_", " ");
  }
}
