import { describe, expect, it } from "vitest";
import {
  candidateRepos, isLive, jobCheck, latestPerWorkflow, matchRepos, neighborTab, openTab, parseRepo, repoStatus, runClock,
  type RunJob, type WorkflowRun,
} from "./actions";
import type { AccountPullRequests, PullRequestItem } from "./connectors";
import { jobId } from "./pulls";

const pull = (repo: string): PullRequestItem => ({
  repo, number: 1, title: "t", url: null, draft: false, updated: null, author: "ada", ci: "unknown", state: "open",
  review: "none", comments: 0, additions: 0, deletions: 0, conflicting: false,
});
const account = (id: string, repos: string[]): AccountPullRequests =>
  ({ id, name: id, login: id, mine: repos.map(pull), reviews: [], watched: [], issues: [], unreadable: [], error: null, errorKind: null }) as unknown as AccountPullRequests;

describe("parseRepo", () => {
  it("takes owner/name and GitHub links", () => {
    expect(parseRepo(" acme/web ")).toBe("acme/web");
    expect(parseRepo("https://github.com/acme/web/actions")).toBe("acme/web");
    expect(parseRepo("github.com/acme/web.git")).toBe("acme/web");
    expect(parseRepo("acme")).toBeNull();
    expect(parseRepo("acme/../x")).toBeNull();
  });
});

describe("candidateRepos", () => {
  it("lists pushed, then pull request, then typed repositories, each once", () => {
    const list = candidateRepos(
      [{ name: "acme/web", account: "work", pushed: "2026-10-01T00:00:00Z" }],
      [account("home", ["Acme/Web", "ada/site"])],
      ["ada/site", "x/y"],
    );
    expect(list.map((r) => r.name)).toEqual(["acme/web", "ada/site", "x/y"]);
    expect(list[1].account).toBe("home");
    expect(list[2].account).toBeNull();
  });
});

describe("runs and jobs", () => {
  it("counts a running run's clock up and leaves a queued one without", () => {
    const start = Date.parse("2026-10-20T12:00:00Z");
    expect(runClock({ started: "2026-10-20T12:00:00Z", finished: null }, start + 75_000)).toBe("1:15");
    expect(runClock({ started: null, finished: null })).toBeNull();
    expect(isLive({ status: "queued" })).toBe(true);
    expect(isLive({ status: "completed" })).toBe(false);
  });

  it("opens a job as a check whose link carries the job id", () => {
    const job: RunJob = {
      id: 9, name: "test", outcome: "cancelled", detail: "cancelled", running: false, started: null, finished: null,
      url: "https://github.com/acme/web/actions/runs/7/job/9",
    };
    const check = jobCheck(job);
    expect(check.outcome).toBe("failing");
    expect(check.checkRun).toBe(true);
    expect(jobId(check.url)).toBe(9);
  });
});

const run = (id: number, workflowId: number, status: string, outcome: WorkflowRun["outcome"]): WorkflowRun => ({
  id, workflowId, workflow: "CI", title: "t", number: id, attempt: 1, branch: "main", sha: "abc", event: "push", actor: "ada",
  status, conclusion: null, outcome, running: status === "in_progress", created: null, started: null, finished: null, url: null,
});

describe("repository tabs", () => {
  it("keeps the tabs in their order and puts a new one first", () => {
    expect(openTab("o/b", ["o/a", "o/b", "o/c"])).toEqual(["o/a", "o/b", "o/c"]);
    expect(openTab("O/B", ["o/a", "o/b"])).toEqual(["o/a", "o/b"]);
    expect(openTab("o/d", ["o/a", "o/b", "o/c"], 3)).toEqual(["o/d", "o/a", "o/b"]);
  });

  it("steps to the tab next to the open one, going round", () => {
    expect(neighborTab(["o/a", "o/b", "o/c"], "o/c", 1)).toBe("o/a");
    expect(neighborTab(["o/a", "o/b", "o/c"], "o/a", -1)).toBe("o/c");
    expect(neighborTab(["o/a"], "o/a", 1)).toBeNull();
  });

  it("finds repositories by owner or name first, then anywhere", () => {
    const repos = ["acme/web", "ada/nook", "acme/nook-site", "x/tool"].map((name) => ({ name }));
    const names = (q: string) => matchRepos(q, repos).map((r) => r.name);
    expect(names("")).toEqual(["acme/web", "ada/nook", "acme/nook-site", "x/tool"]);
    expect(names("nook")).toEqual(["ada/nook", "acme/nook-site"]);
    expect(names("t")).toEqual(["x/tool", "acme/nook-site"]);
  });

  it("marks a tab while something runs or a workflow's newest run failed", () => {
    expect(repoStatus([])).toBeNull();
    expect(repoStatus([run(3, 1, "completed", "passing"), run(2, 1, "completed", "failing")])?.outcome).toBe("passing");
    const broken = repoStatus([run(4, 1, "completed", "passing"), run(3, 2, "completed", "failing")]);
    expect(broken).toMatchObject({ outcome: "failing", failing: 1, active: 0 });
    const busy = repoStatus([run(5, 1, "in_progress", "pending"), run(4, 2, "completed", "failing")]);
    expect(busy).toMatchObject({ outcome: "pending", running: true, active: 1, failing: 1 });
    expect(latestPerWorkflow([run(5, 1, "in_progress", "pending"), run(4, 1, "completed", "failing")]).get(1)?.id).toBe(5);
  });
});
