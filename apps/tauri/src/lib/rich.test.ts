import { describe, expect, it } from "vitest";
import { hasRich, splitMath } from "./rich";

describe("diagrams and math", () => {
  it("finds what there is to draw", () => {
    expect(hasRich("```mermaid\ngraph TD\n```")).toBe(true);
    expect(hasRich("The energy $E = mc^2$ is famous")).toBe(true);
    expect(hasRich("$$\\int x$$")).toBe(true);
    expect(hasRich("It costs $5 and $10")).toBe(false);
    expect(hasRich("plain text")).toBe(false);
  });
  it("splits math out of text", () => {
    expect(splitMath("a $x^2$ b")).toEqual([{ text: "a " }, { math: "x^2", display: false }, { text: " b" }]);
    expect(splitMath("$$\\sum i$$")).toEqual([{ math: "\\sum i", display: true }]);
    expect(splitMath("costs $5 or $6")).toEqual([{ text: "costs $5 or $6" }]);
  });
});
