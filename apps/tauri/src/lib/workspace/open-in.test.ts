import { describe, expect, it } from "vitest";
import { linkOpensInNook, searchEngines } from "./open-in";

describe("Editor & browser", () => {
  it("opens an agent's link where chosen, and the other way with Ctrl", () => {
    expect(linkOpensInNook("app", false)).toBe(true);
    expect(linkOpensInNook("app", true)).toBe(false);
    expect(linkOpensInNook("system", false)).toBe(false);
    expect(linkOpensInNook("system", true)).toBe(true);
  });

  it("offers the Mac's search engines in its order", () => {
    expect(searchEngines.map((e) => e.id)).toEqual(["duckduckgo", "google", "bing", "brave", "kagi", "startpage", "ecosia"]);
  });
});
