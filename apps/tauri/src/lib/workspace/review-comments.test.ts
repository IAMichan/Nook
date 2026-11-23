import { describe, expect, it } from "vitest";
import { quote, reviewMessage } from "./review-comments.svelte";

describe("review comments", () => {
  it("writes one message with a block per comment", () => {
    const out = reviewMessage([
      { id: "1", path: "src/a.ts", line: 12, code: "+let x = 1;", text: " Use const " },
      { id: "2", path: "src/b.ts", line: null, code: "-old()", text: "Why removed?" },
    ]);
    expect(out).toBe(
      'Review comments on your changes. Address each one:\n\n<review_comment file="src/a.ts" line="12">\n> +let x = 1;\nUse const\n</review_comment>\n\n<review_comment file="src/b.ts">\n> -old()\nWhy removed?\n</review_comment>',
    );
  });

  it("quotes into a draft", () => {
    expect(quote("a\nb", "next")).toBe("> a\n> b\n\nnext");
  });
});
