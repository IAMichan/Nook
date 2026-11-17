import { describe, expect, it } from "vitest";
import type { PullDigest } from "./companion";
import { counted, parseQuery, sections, sorted } from "./companion-pulls";

const pull = (number: number, o: Partial<PullDigest> = {}): PullDigest => ({
  url: `https://github.com/o/r/pull/${number}`, repo: "o/r", number, title: `Pull ${number}`, author: "ada", state: "open", ci: "unknown",
  review: "none", conflict: false, additions: 0, deletions: 0, updated: 0, group: "mine", headBranch: "feature", baseBranch: "main", ...o,
});

describe("the phone's pull request list, as the Mac's", () => {
  it("counts the chips", () => {
    const pulls = [pull(1, { group: "review" }), pull(2, { group: "review", state: "draft" }), pull(3, { group: "review", state: "merged" }),
      pull(4, { ci: "failing" }), pull(5, { ci: "passing", review: "approved" }), pull(6, { ci: "passing", review: "approved", conflict: true })];
    expect(counted(pulls)).toEqual({ review: 2, failing: 1, ready: 1 });
    expect(counted(pulls, "#4")).toEqual({ review: 0, failing: 1, ready: 0 });
  });

  it("reads the search's qualifiers", () => {
    const q = parseQuery("fix label:bug,ui -label:wip author:@Ada repo:o/r branch:feat draft:false review:approved checks:failing area:ui");
    expect(q.words).toEqual(["fix"]);
    expect(q.labels).toEqual([["bug", "ui"], ["area:ui"]]);
    expect(q.excludedLabels).toEqual(["wip"]);
    expect([q.author, q.repo, q.branch, q.draft, q.review, q.checks]).toEqual(["ada", "o/r", "feat", false, "approved", "failing"]);
  });

  it("filters, sorts and groups", () => {
    const pulls = [pull(1, { updated: 10, additions: 5, labels: ["Bug"] }), pull(2, { ci: "failing", updated: 5, additions: 50 }),
      pull(3, { ci: "passing", review: "approved", updated: 1, additions: 1, group: "review", repo: "x/y" })];
    expect(sorted(pulls, "attention").map((p) => p.number)).toEqual([3, 2, 1]);
    expect(sorted(pulls, "largest").map((p) => p.number)).toEqual([2, 1, 3]);
    expect(sections(pulls, { query: "label:bug" }).flatMap((s) => s.pulls.map((p) => p.number))).toEqual([1]);
    expect(sections(pulls).map((s) => s.key)).toEqual(["review", "mine"]);
    expect(sections(pulls, { grouping: "repository", sort: "recent" }).map((s) => s.key)).toEqual(["o/r", "x/y"]);
    expect(sections([pull(9, { state: "merged" })], { state: "merged" }).length).toBe(1);
  });
});
