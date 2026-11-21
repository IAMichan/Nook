import { describe, expect, it } from "vitest";
import { anchorCorrection, gap, heldHeight, keyDirection, nearEnd, reaction } from "./end-follow";

const at = (scrollTop: number, scrollHeight = 2000, clientHeight = 500) => ({ scrollTop, scrollHeight, clientHeight });

describe("following the end", () => {
  it("measures the distance to the end", () => {
    expect(gap(at(1500))).toBe(0);
    expect(gap(at(1400))).toBe(100);
    expect(nearEnd(at(1480))).toBe(true);
    expect(nearEnd(at(1400))).toBe(false);
  });

  it("lets go on a step up, even one that ends near the end", () => {
    // The bug on Windows and Linux: a small step up from the end stayed within reach of it and kept following.
    expect(reaction(true, "up", at(1490))).toBe(false);
    expect(reaction(true, "up", at(0))).toBe(false);
  });

  it("follows again only on a step down that reaches the end", () => {
    expect(reaction(false, "down", at(1500))).toBe(true);
    expect(reaction(false, "down", at(1000))).toBe(false);
    // Being at the end without a step of your own (text streaming in) changes nothing.
    expect(reaction(false, "none", at(1500))).toBe(false);
    expect(reaction(true, "none", at(200))).toBe(true);
  });

  it("knows which keys scroll", () => {
    expect(keyDirection("PageUp")).toBe("up");
    expect(keyDirection("ArrowUp")).toBe("up");
    expect(keyDirection("Home")).toBe("up");
    expect(keyDirection("End")).toBe("down");
    expect(keyDirection(" ")).toBe("down");
    expect(keyDirection(" ", true)).toBe("up");
    expect(keyDirection("a")).toBeNull();
  });

  it("holds the height while working and lets it go after", () => {
    expect(heldHeight(1200, 1000, true)).toBe(1200);
    expect(heldHeight(1200, 1400, true)).toBe(1400);
    expect(heldHeight(1200, 1000, false)).toBe(1000);
  });

  it("scrolls by how far the row you read moved", () => {
    expect(anchorCorrection(40, 340)).toBe(300);
    expect(anchorCorrection(40, -10)).toBe(-50);
    expect(anchorCorrection(40, 40.2)).toBe(0);
  });
});
