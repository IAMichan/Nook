import { describe, expect, it } from "vitest";
import { cleanTrigger, render, variables } from "./prompts.svelte";

describe("saved prompts", () => {
  it("asks each variable once and fills in defaults", () => {
    const body = "Review {{file}} for {{focus|bugs}}; then {{file}} again.";
    expect(variables(body)).toEqual([{ name: "file", defaultValue: "" }, { name: "focus", defaultValue: "bugs" }]);
    expect(render(body, { file: "a.rs" })).toBe("Review a.rs for bugs; then a.rs again.");
    expect(cleanTrigger("/Sum Up!")).toBe("sumup");
  });
});
