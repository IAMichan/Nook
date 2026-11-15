import { describe, expect, it } from "vitest";
import { lineComment, newNumbers, positions, reviewComment, withReviewComment } from "./patch";

const patch = ["@@ -10,3 +10,4 @@", " a", "-b", "+B", "+C", " d", "\\ No newline at end of file"];

describe("patch positions", () => {
  it("numbers lines as GitHub does", () => {
    expect(positions(patch)).toEqual([null, { line: 10, side: "RIGHT" }, { line: 11, side: "LEFT" }, { line: 11, side: "RIGHT" }, { line: 12, side: "RIGHT" }, { line: 13, side: "RIGHT" }, null]);
    expect(newNumbers(patch)).toEqual([null, 10, null, 11, 12, 13, null]);
  });

  it("puts a comment on the last picked line, from the first on its side", () => {
    expect(lineComment("f.ts", 3, 4, positions(patch), "x")).toEqual({ path: "f.ts", line: 12, side: "RIGHT", body: "x", startLine: 11 });
    expect(lineComment("f.ts", 2, 2, positions(patch), "x")).toEqual({ path: "f.ts", line: 11, side: "LEFT", body: "x", startLine: undefined });
    expect(lineComment("f.ts", 0, 0, positions(patch), "x")).toBeNull();
  });

  it("writes the review block the Mac's review sends", () => {
    const block = reviewComment("f.ts", patch, newNumbers(patch), 3, 4, "Why two?");
    expect(block).toBe('<review_comment file="f.ts" line="11">\n> +B\n> +C\nWhy two?\n</review_comment>');
    expect(withReviewComment("", block).startsWith("Review comments on your changes. Address each one:\n\n<review_comment")).toBe(true);
    expect(withReviewComment("Also this", block).startsWith("Also this\n\n")).toBe(true);
  });
});
