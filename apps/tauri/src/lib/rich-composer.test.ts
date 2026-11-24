import { describe, expect, it } from "vitest";
import { hasMarkdown, richRuns } from "@nook/web-ui/rich";

const styled = (text: string) => richRuns(text).filter((r) => r.styles.length).map((r) => [r.text, r.styles.join("+")]);

describe("rich composer", () => {
  it("keeps every character, so the caret lines up", () => {
    for (const text of ["# Title\n- **bold** and *it* `code`\n> quote ~~old~~ [a](http://x)\n```\nlet a = *b*\n```\nend", "plain", "", "a*b*c **x", "\n\n"]) {
      expect(richRuns(text).map((r) => r.text).join("")).toBe(text);
    }
  });

  it("styles headings, lists, quotes, inline marks and code blocks", () => {
    expect(styled("# Hi **there**")).toEqual([["# ", "heading+marker"], ["Hi ", "heading"], ["**", "heading+bold+marker"], ["there", "heading+bold"], ["**", "heading+bold+marker"]]);
    expect(styled("1. _x_")).toEqual([["1. ", "list+marker"], ["_", "italic+marker"], ["x", "italic"], ["_", "italic+marker"]]);
    expect(styled("```\n*no*\n```")[1]).toEqual(["*no*\n", "codeBlock"]);
    expect(styled("snake_case_name and 2*3*4")).toEqual([]);
    expect(hasMarkdown("just words")).toBe(false);
  });
});
