import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  COPIED_MS,
  CopiedMoment,
  REFRESH_PULSE_MS,
  RefreshPulse,
  TIP_REST_MS,
  TipClock,
  cutMiddle,
  isRedundantTip,
  placeTip,
  shouldShowTipText,
} from "./ui-parts";

describe("TipClock", () => {
  it("rests before the first tip and swaps at once to the next within 400 ms", () => {
    const clock = new TipClock();
    expect(clock.enter(1000)).toBe(TIP_REST_MS);
    clock.shown();
    clock.leave(1200);
    expect(clock.enter(1500)).toBe(0);
    clock.shown();
    clock.leave(1600);
    expect(clock.enter(2100)).toBe(TIP_REST_MS);
  });

  it("does not count a tip that never showed", () => {
    const clock = new TipClock();
    clock.enter(0);
    clock.leave(100);
    expect(clock.enter(200)).toBe(TIP_REST_MS);
  });

  it("rests again after a click", () => {
    const clock = new TipClock();
    clock.shown();
    clock.dismiss();
    expect(clock.enter(10)).toBe(TIP_REST_MS);
  });
});

describe("placeTip", () => {
  const view = { width: 800, height: 600 };
  const size = { width: 100, height: 24 };
  it("centers under the control", () => {
    expect(placeTip({ left: 300, top: 100, width: 40, height: 20 }, size, view)).toEqual({ left: 270, top: 126, edge: "bottom" });
  });
  it("flips above at the bottom of the window", () => {
    const p = placeTip({ left: 300, top: 570, width: 40, height: 20 }, size, view);
    expect(p.edge).toBe("top");
    expect(p.top).toBe(570 - 6 - 24);
  });
  it("clamps at the sides", () => {
    expect(placeTip({ left: 0, top: 100, width: 20, height: 20 }, size, view).left).toBe(8);
    expect(placeTip({ left: 790, top: 100, width: 10, height: 20 }, size, view).left).toBe(800 - 8 - 100);
  });
  it("keeps the asked edge when it fits", () => {
    expect(placeTip({ left: 300, top: 100, width: 40, height: 20 }, size, view, "top").edge).toBe("top");
    expect(placeTip({ left: 300, top: 10, width: 40, height: 20 }, size, view, "top").edge).toBe("bottom");
  });
});

describe("CopiedMoment", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  it("ends after 1.5 s and a second copy restarts it", () => {
    const seen: boolean[] = [];
    const moment = new CopiedMoment((c) => seen.push(c));
    moment.copied();
    vi.advanceTimersByTime(COPIED_MS - 100);
    moment.copied();
    vi.advanceTimersByTime(COPIED_MS - 100);
    expect(seen).toEqual([true, true]);
    vi.advanceTimersByTime(100);
    expect(seen).toEqual([true, true, false]);
  });
});

describe("cutMiddle", () => {
  it("keeps short text and cuts long text in the middle", () => {
    expect(cutMiddle("short", 10)).toBe("short");
    const cut = cutMiddle("/Users/me/Code/project/src/components/File.svelte", 24);
    expect(cut).toHaveLength(24);
    expect(cut.startsWith("/Users/me/")).toBe(true);
    expect(cut.endsWith("File.svelte")).toBe(true);
  });
});

describe("tooltip cut-off rules (UI-41)", () => {
  it("suppresses tooltips that only repeat visible text unless cut off", () => {
    expect(isRedundantTip("My Session", "  My   Session ")).toBe(true);
    expect(shouldShowTipText("My Session", "My Session", false)).toBe(false);
    expect(shouldShowTipText("My Session", "My Session", true)).toBe(true);
  });

  it("shows icon button and explanatory tooltips without requiring truncation", () => {
    expect(shouldShowTipText("Refresh", "", false)).toBe(true);
    expect(shouldShowTipText("Open this repository on GitHub", "GitHub", false)).toBe(true);
    expect(shouldShowTipText("   ", "", true)).toBe(false);
  });

  it("respects explicit whenCut even when text differs", () => {
    expect(shouldShowTipText("Full title", "Short", false, true)).toBe(false);
    expect(shouldShowTipText("Full title", "Short", true, true)).toBe(true);
  });
});

describe("RefreshPulse (UI-41)", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());
  it("keeps the refresh icon turning for at least REFRESH_PULSE_MS and restarts on re-click", () => {
    const states: boolean[] = [];
    const pulse = new RefreshPulse((on) => states.push(on));
    pulse.trigger();
    vi.advanceTimersByTime(REFRESH_PULSE_MS - 50);
    pulse.trigger();
    vi.advanceTimersByTime(REFRESH_PULSE_MS - 50);
    expect(states).toEqual([true, true]);
    vi.advanceTimersByTime(50);
    expect(states).toEqual([true, true, false]);
  });
});
