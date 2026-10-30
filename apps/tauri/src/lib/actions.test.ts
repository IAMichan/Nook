import { describe, expect, it } from "vitest";
import { candidateRepos, isLive, jobCheck, parseRepo, runClock, type RunJob } from "./actions";
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
