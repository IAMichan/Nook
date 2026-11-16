import { describe, expect, it } from "vitest";
import { CHARACTER_LIMIT, isDeliberate, message, offered, origin, skips, wanted, type ElementLike } from "./selection-ask";

// A stand-in for an element: `closest` matches when the element sits in one of `inside` (by selector part).
const el = (...inside: string[]): ElementLike => ({
  closest: (selector: string) => (selector.split(",").some((part) => inside.includes(part.trim())) ? {} : null),
});

describe("offered", () => {
  it("trims and normalizes line breaks", () => {
    expect(offered("  hello\r\nworld\u2028again  ")).toBe("hello\nworld\nagain");
  });

  it("refuses a single character, spaces, or punctuation only", () => {
    expect(offered("a")).toBeNull();
    expect(offered("   ")).toBeNull();
    expect(offered("…!?")).toBeNull();
    expect(offered("ok")).toBe("ok");
    expect(offered("日本")).toBe("日本");
  });

  it("cuts a long selection with an ellipsis", () => {
    const cut = offered("word ".repeat(2000))!;
    expect([...cut].length).toBeLessThanOrEqual(CHARACTER_LIMIT);
    expect(cut.endsWith("…")).toBe(true);
  });
});

describe("message", () => {
  it("quotes every line, then the instruction", () => {
    expect(message("one\ntwo", "Explain this in plain words.")).toBe("> one\n> two\n\nExplain this in plain words.");
  });
});

describe("isDeliberate", () => {
  it("is a drag or a double click, not a plain click", () => {
    expect(isDeliberate({ x: 0, y: 0 }, { x: 1, y: 1 }, 1)).toBe(false);
    expect(isDeliberate({ x: 0, y: 0 }, { x: 10, y: 0 }, 1)).toBe(true);
    expect(isDeliberate({ x: 0, y: 0 }, { x: 0, y: 0 }, 2)).toBe(true);
  });
});

describe("origin", () => {
  const visible = { left: 0, top: 0, width: 1000, height: 800 };
  const size = { width: 300, height: 36 };

  it("centres the bar above the selection", () => {
    expect(origin(size, { left: 400, top: 300, width: 200, height: 20 }, visible)).toEqual({ x: 350, y: 256 });
  });

  it("goes under the selection when there is no room above", () => {
    expect(origin(size, { left: 400, top: 10, width: 200, height: 20 }, visible)).toEqual({ x: 350, y: 38 });
  });

  it("puts the card under the selection, or above it near the bottom", () => {
    const card = { width: 400, height: 300 };
    expect(origin(card, { left: 400, top: 100, width: 200, height: 20 }, visible, true)).toEqual({ x: 300, y: 128 });
    expect(origin(card, { left: 400, top: 700, width: 200, height: 20 }, visible, true)).toEqual({ x: 300, y: 392 });
  });

  it("stays inside the window at the edges", () => {
    expect(origin(size, { left: 0, top: 300, width: 20, height: 20 }, visible).x).toBe(8);
    expect(origin(size, { left: 990, top: 300, width: 10, height: 20 }, visible).x).toBe(1000 - 300 - 8);
    // Taller than the window: pinned to its top.
    expect(origin({ width: 300, height: 900 }, { left: 400, top: 300, width: 20, height: 20 }, visible, true).y).toBe(0);
  });
});

describe("wanted", () => {
  const text = { text: "What does this mean?", collapsed: false, start: el(), end: el() };

  it("offers a selection in ordinary text", () => {
    expect(wanted(true, text)).toBe("What does this mean?");
  });

  it("stays away when off, collapsed, or empty", () => {
    expect(wanted(false, text)).toBeNull();
    expect(wanted(true, null)).toBeNull();
    expect(wanted(true, { ...text, collapsed: true })).toBeNull();
    expect(wanted(true, { ...text, text: " " })).toBeNull();
  });

  it("stays out of fields and out of its own bar and card", () => {
    expect(wanted(true, { ...text, start: el("textarea"), end: el("textarea") })).toBeNull();
    expect(wanted(true, { ...text, end: el("input") })).toBeNull();
    expect(wanted(true, { ...text, start: el("[contenteditable]:not([contenteditable='false'])") })).toBeNull();
    expect(wanted(true, { ...text, start: el(".selection-ask") })).toBeNull();
    expect(skips(null)).toBe(true);
  });
});
