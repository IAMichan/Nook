import { describe, expect, it } from "vitest";
import { handleBack, onBack, parseInsets } from "./mobile";

describe("mobile", () => {
  it("reads insets from the Android bridge and ignores nonsense", () => {
    expect(parseInsets('{"top":24.4,"bottom":48,"left":0,"right":0,"keyboard":310}')).toEqual({ top: 24, bottom: 48, left: 0, right: 0, keyboard: 310 });
    expect(parseInsets('{"top":-5,"bottom":"x"}')).toEqual({ top: 0, bottom: 0, left: 0, right: 0, keyboard: 0 });
    expect(parseInsets("not json")).toBeNull();
    expect(parseInsets(null)).toBeNull();
  });

  it("gives the back button to the newest screen that wants it", () => {
    const calls: string[] = [];
    const offList = onBack(() => (calls.push("list"), true));
    const offDetail = onBack(() => (calls.push("detail"), true));
    expect(handleBack()).toBe(true);
    offDetail();
    expect(handleBack()).toBe(true);
    offList();
    expect(handleBack()).toBe(false);
    expect(calls).toEqual(["detail", "list"]);
  });
});
