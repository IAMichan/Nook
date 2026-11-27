import { describe, expect, it } from "vitest";
import {
  badgeFromLinks,
  emptyPullRequestSyncSnapshot,
  foldBranchRows,
  isStack,
  linkedPullRequests,
  linkId,
  orderStack,
  sessionBranchRows,
  SHOWN_WHEN_FOLDED,
  type PullRequestLink,
  type PullRequestState,
} from "./pull-requests";

function pr(
  number: number,
  opts: Partial<PullRequestLink> & { state?: PullRequestState } = {},
): PullRequestLink {
  return {
    host: { kind: "github" },
    repository: opts.repository ?? "acme/app",
    number,
    url: opts.url ?? `https://github.com/acme/app/pull/${number}`,
    title: opts.title ?? `PR #${number}`,
    state: opts.state ?? "open",
    updatedAt: opts.updatedAt ?? null,
    baseBranch: opts.baseBranch ?? "main",
    headBranch: opts.headBranch ?? `feat-${number}`,
    conflicted: opts.conflicted ?? false,
  };
}

describe("pull-requests helpers (AG-104)", () => {
  it("detects and orders stacked pull requests bottom-to-top", () => {
    const a = pr(10, { baseBranch: "main", headBranch: "feat/a" });
    const b = pr(11, { baseBranch: "feat/a", headBranch: "feat/b" });
    const c = pr(12, { baseBranch: "feat/b", headBranch: "feat/c" });

    expect(isStack([c, a, b])).toBe(true);
    expect(isStack([a, pr(20, { baseBranch: "main", headBranch: "feat/other" })])).toBe(false);

    const ordered = orderStack([c, b, a]);
    expect(ordered.map((x) => [x.link.number, x.depth])).toEqual([
      [10, 0],
      [11, 1],
      [12, 2],
    ]);
  });

  it("formats row badges for single PR, multiple PRs, conflict, and stacks", () => {
    expect(badgeFromLinks([])).toBeNull();

    const single = badgeFromLinks([pr(42, { state: "draft" })]);
    expect(single).toEqual({ glyph: "draft", label: { kind: "number", number: 42 } });

    const conflict = badgeFromLinks([pr(7, { state: "open", conflicted: true })]);
    expect(conflict).toEqual({ glyph: "conflict", label: { kind: "number", number: 7 } });

    const multi = badgeFromLinks([
      pr(1, { state: "merged" }),
      pr(5, { state: "open" }),
      pr(2, { state: "closed" }),
    ]);
    expect(multi).toEqual({ glyph: "open", label: { kind: "numberPlus", number: 5, extra: 2 } });

    const stack = badgeFromLinks([
      pr(10, { baseBranch: "main", headBranch: "a", state: "merged" }),
      pr(11, { baseBranch: "a", headBranch: "b", state: "open" }),
      pr(12, { baseBranch: "b", headBranch: "c", state: "draft" }),
    ]);
    expect(stack).toEqual({ glyph: "stack", label: { kind: "stack", count: 3, merged: 1 } });

    const allMergedStack = badgeFromLinks([
      pr(10, { baseBranch: "main", headBranch: "a", state: "merged" }),
      pr(11, { baseBranch: "a", headBranch: "b", state: "merged" }),
    ]);
    expect(allMergedStack).toEqual({ glyph: "merged", label: { kind: "stack", count: 2, merged: 2 } });
  });

  it("merges branch, earlier, and added PRs while filtering dismissed entries", () => {
    const snap = emptyPullRequestSyncSnapshot();
    const p1 = pr(1, { state: "merged", headBranch: "feat/one" });
    const p2 = pr(2, { state: "open", headBranch: "feat/two" });
    const p3 = pr(3, { state: "open", headBranch: "feat/three" });
    snap.earlier["run-1"] = [p1];
    snap.links["run-1"] = [p2];
    snap.added["run-1"] = [p2, p3]; // p2 duplicates current branch
    snap.dismissed["run-1"] = [linkId(p1)];

    const lines = linkedPullRequests(snap, "run-1", "/repo", "feat/two");
    expect(lines.map((l) => [l.link.number, l.source])).toEqual([
      [3, "added"],
      [2, "branch"],
    ]);
  });

  it("builds session branch tray rows oldest-first and folds older rows cleanly", () => {
    const snap = emptyPullRequestSyncSnapshot();
    snap.earlierBranches["run-1"] = ["feat/1", "feat/2", "feat/3", "feat/4"];
    snap.earlier["run-1"] = [
      pr(1, { state: "merged", headBranch: "feat/1" }),
      pr(2, { state: "merged", headBranch: "feat/2" }),
      pr(4, { state: "closed", headBranch: "feat/4" }),
    ];
    snap.links["run-1"] = [pr(5, { state: "open", headBranch: "feat/5" })];

    const rows = sessionBranchRows(snap, "run-1", "/repo", "feat/5");
    expect(rows.map((r) => [r.branch, r.pullRequest?.number ?? null, r.isCurrent])).toEqual([
      ["feat/1", 1, false],
      ["feat/2", 2, false],
      ["feat/3", null, false],
      ["feat/4", 4, false],
      ["feat/5", 5, true],
    ]);

    const folded = foldBranchRows(rows, false);
    expect(folded.shown.length).toBe(SHOWN_WHEN_FOLDED);
    expect(folded.hiddenCount).toBe(2);
    expect(folded.hiddenPrCount).toBe(2);

    const expanded = foldBranchRows(rows, true);
    expect(expanded.shown.length).toBe(5);
    expect(expanded.hiddenCount).toBe(0);
  });
});
