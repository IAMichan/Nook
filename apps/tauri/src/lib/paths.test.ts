import { describe, expect, it } from "vitest";
import { looksLikePath } from "./paths";

describe("pasted paths", () => {
  it("knows a path from text", () => {
    for (const p of ["/Users/me/Projects/nook", "~/Documents/plan.pdf", "C:\\Users\\me\\offer.docx", "D:/work/data.zip", "\\\\server\\share\\x.txt", "file:///home/me/a.md"]) {
      expect(looksLikePath(p), p).toBe(true);
    }
    for (const t of ["hello", "/ divide", "see /Users/me", "/a\n/b", "https://example.com", ""]) {
      expect(looksLikePath(t), t).toBe(false);
    }
  });
});
