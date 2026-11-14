import { describe, expect, it } from "vitest";
import { ACCENTS, LIGHT_ACCENT, isDensity, resolveTheme, themeAccent } from "./theme";

describe("theme", () => {
  it("follows the setting, the system for System, and stays dark for old or unknown values", () => {
    expect(resolveTheme("light", true)).toBe("light");
    expect(resolveTheme("dark", false)).toBe("dark");
    expect(resolveTheme("system", true)).toBe("dark");
    expect(resolveTheme("system", false)).toBe("light");
    expect(resolveTheme(undefined, false)).toBe("dark");
    expect(resolveTheme("sepia", false)).toBe("dark");
  });

  it("turns the soft white accent near-black in light and keeps colored accents", () => {
    expect(themeAccent(0xf4f3f7, "light")).toBe(LIGHT_ACCENT);
    expect(themeAccent(0xf4f3f7, "dark")).toBe(0xf4f3f7);
    for (const a of ACCENTS.slice(1)) expect(themeAccent(a, "light")).toBe(a);
  });

  it("knows the densities", () => {
    expect(isDensity("compact")).toBe(true);
    expect(isDensity("huge")).toBe(false);
  });
});
