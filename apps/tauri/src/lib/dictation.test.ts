import { describe, expect, it } from "vitest";
import { withDictated } from "./dictation.svelte";

describe("dictation", () => {
  it("puts what is heard after what was typed", () => {
    expect(withDictated("", "hello there")).toBe("hello there");
    expect(withDictated("Fix it", "and test")).toBe("Fix it and test");
    expect(withDictated("Fix it ", "and test")).toBe("Fix it and test");
    expect(withDictated("Fix it", "")).toBe("Fix it");
  });
});
