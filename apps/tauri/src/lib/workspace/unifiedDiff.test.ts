import { describe, expect, it } from "vitest";
import { changedRanges, diffRows, hunk, hunkLabel, lineRows } from "./unifiedDiff";

describe("unified diff", () => {
  it("numbers lines on both sides", () => {
    const diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -10,3 +12,4 @@ fn run()\n keep\n-gone\n+new\n+newer\n end\n";
    const rows = diffRows(diff);
    expect(rows.map((r) => r.kind)).toEqual(["hunk", "context", "remove", "add", "add", "context"]);
    expect(rows.map((r) => r.old)).toEqual([10, 10, 11, null, null, 12]);
    expect(rows.map((r) => r.new)).toEqual([12, 12, null, 13, 14, 15]);
    expect(rows[0].text).toBe("fn run()");
    expect(rows[2].text).toBe("gone");
    expect(rows[3].raw).toBe("+new");
  });

  it("shows file rows only for several files", () => {
    const one = diffRows("diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-a\n+b");
    expect(one.some((r) => r.kind === "file")).toBe(false);
    const two = diffRows("diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/c/d.txt b/c/d.txt\nnew file mode 100644\n@@ -0,0 +1 @@\n+d");
    expect(two.filter((r) => r.kind === "file").map((r) => r.text)).toEqual(["a.txt", "c/d.txt"]);
    expect(two.some((r) => r.kind === "note" && r.text === "new file mode 100644")).toBe(true);
    expect(two[two.length - 1].new).toBe(1);
  });

  it("marks the changed part of an edited line", () => {
    const rows = diffRows("@@ -1,2 +1,2 @@\n-let total = price * 2\n+let total = price * 3\n\\ No newline at end of file");
    expect(rows[1].changed).toEqual([20, 21]);
    expect(rows[2].changed).toEqual([20, 21]);
    expect(rows[3].kind).toBe("note");
    // Lines that share almost nothing are simply replaced.
    expect(changedRanges("alpha beta gamma", "x")[0]).toBeNull();
  });

  it("reads hunk headers", () => {
    expect(hunk("@@ -90,7 +91,8 @@ <section>").old).toBe(90);
    expect(hunk("@@ -90,7 +91,8 @@ <section>").new).toBe(91);
    expect(hunk("@@ -1 +1 @@").section).toBe("");
    expect(hunkLabel("@@ -1 +1 @@ fn x")).toBe("@@ -1 +1 @@");
  });
});

describe("edit diffs", () => {
  it("strip the marker and highlight the edit", () => {
    const rows = lineRows([
      { kind: "context", text: "  fn a() {" },
      { kind: "remove", text: "- let x = 1;" },
      { kind: "add", text: "+ let x = 2;" },
    ]);
    expect(rows.map((r) => r.text)).toEqual(["fn a() {", "let x = 1;", "let x = 2;"]);
    expect(rows[2].changed).toEqual([8, 9]);
  });
});
