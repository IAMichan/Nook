import { describe, expect, it } from "vitest";
import { accessOf, nextAccess } from "./access";

describe("access levels", () => {
  it("cycles ask → small → more → ask", () => {
    expect(nextAccess("ask")).toBe("small");
    expect(nextAccess("small")).toBe("more");
    expect(nextAccess("more")).toBe("ask");
  });

  it("takes the old switch until a level is chosen", () => {
    expect(accessOf({ nookAccess: null, autoRunSafe: true })).toBe("small");
    expect(accessOf({ nookAccess: undefined, autoRunSafe: false })).toBe("ask");
    expect(accessOf({ nookAccess: "more", autoRunSafe: false })).toBe("more");
  });
});
