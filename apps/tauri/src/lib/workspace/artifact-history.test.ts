import { describe, expect, it } from "vitest";
import { ArtifactHistory, HISTORY_LIMIT, historyOf, lineCounts, recordVersion, unifiedDiff } from "./artifact-history";
import { diffRows } from "./unifiedDiff";

describe("artifact history", () => {
  it("records a new text once and numbers versions from 1", () => {
    const h = new ArtifactHistory();
    expect(h.record("a", 1)).toBe(true);
    expect(h.record("a", 2)).toBe(false);
    expect(h.record("b", 3)).toBe(true);
    expect(h.versions.map((v) => v.number)).toEqual([1, 2]);
    expect(h.previous(2)?.text).toBe("a");
    expect(h.previous(1)).toBeUndefined();
  });
  it("drops the oldest past the limit", () => {
    const h = new ArtifactHistory();
    for (let i = 0; i < HISTORY_LIMIT + 5; i += 1) h.record(String(i));
    expect(h.versions).toHaveLength(HISTORY_LIMIT);
    expect(h.versions[0].number).toBe(6);
  });
  it("keeps histories per file", () => {
    expect(recordVersion("/h/a.md", "x")).toBe(true);
    expect(recordVersion("/h/a.md", "x")).toBe(false);
    expect(historyOf("/h/a.md").versions).toHaveLength(1);
    expect(historyOf("/h/none.md").versions).toHaveLength(0);
  });
  it("counts and writes a unified diff the diff viewer reads", () => {
    const old = "a\nb\nc\nd\ne\nf\ng\nh\n";
    const next = "a\nB\nc\nd\ne\nf\ng\nh\ni\n";
    expect(lineCounts(old, next)).toEqual({ added: 2, removed: 1 });
    const diff = unifiedDiff(old, next, "n.txt");
    expect(diff).toContain("@@ -1,8 +1,9 @@");
    expect(diff).toContain("-b\n+B");
    expect(diff.startsWith("diff --git a/n.txt b/n.txt\n--- a/n.txt\n+++ b/n.txt\n")).toBe(true);
    expect(diffRows(diff).some((r) => r.kind === "add")).toBe(true);
    expect(unifiedDiff("same\n", "same\n", "n")).toBe("");
  });
  it("shows an empty side as the line before the change", () => {
    expect(unifiedDiff("", "x\n", "n")).toContain("@@ -0,0 +1,1 @@");
  });
});
