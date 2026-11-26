import { describe, expect, it } from "vitest";
import { settingNoteMeta } from "./setting-note";

describe("settingNoteMeta", () => {
  it("keeps info plain without an icon", () => {
    expect(settingNoteMeta()).toEqual({ icon: null, toneClass: "info" });
    expect(settingNoteMeta("info")).toEqual({ icon: null, toneClass: "info" });
  });

  it("pairs success, warning, and error tones with distinct icons", () => {
    expect(settingNoteMeta("success")).toEqual({ icon: "circle-check", toneClass: "success" });
    expect(settingNoteMeta("warning")).toEqual({ icon: "triangle-alert", toneClass: "warning" });
    expect(settingNoteMeta("error")).toEqual({ icon: "octagon-alert", toneClass: "error" });
  });
});
