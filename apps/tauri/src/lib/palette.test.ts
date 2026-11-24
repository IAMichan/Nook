import { describe, expect, it } from "vitest";
import {
  BUILT_IN, NOOK_DARK, NOOK_LIGHT, allThemes, contrast, cssHex, diffColors, importVSCodeTheme, lookFile, mix, paletteVars, parseColor, readLook,
  stripComments, themePalette, withOverrides,
} from "./palette";

describe("palette", () => {
  it("mixes and measures colors as NookColor does", () => {
    expect(mix(0x000000, 0xffffff, 0.5)).toBe(0x808080);
    expect(contrast(0x000000, 0xffffff)).toBeCloseTo(21, 5);
    expect(parseColor("#fff")).toBe(0xffffff);
    expect(parseColor("#00000080", 0xffffff)).toBe(0x7f7f7f);
    expect(parseColor("red")).toBeNull();
  });

  it("has the Mac's built-in themes, each readable in dark and light", () => {
    expect(BUILT_IN.map((t) => t.id)).toEqual(["nook", "warm", "mono", "midnight", "paper", "contrast"]);
    for (const theme of BUILT_IN.slice(1)) {
      for (const p of [theme.dark!, theme.light!]) {
        for (const text of [p.textStrong, p.textSecondary, p.textMuted, p.textTertiary]) {
          for (const surface of [p.canvas, p.well, p.surface, p.field, p.graphite, p.smoke, p.rowSelected]) {
            expect(contrast(text, surface)).toBeGreaterThanOrEqual(4.5);
          }
        }
      }
    }
  });

  it("sets no variables for Nook's own theme, and every changed one for another", () => {
    expect(paletteVars(NOOK_DARK, NOOK_DARK)).toEqual({});
    const warm = themePalette(BUILT_IN, "warm", true);
    expect(paletteVars(warm, NOOK_DARK)["--canvas"]).toBe(cssHex(0x1f1e1b));
    // A theme that is gone falls back to Nook's own.
    expect(themePalette(BUILT_IN, "gone", false)).toBe(NOOK_LIGHT);
  });

  it("lays colors you set over the theme and draws diffs blue and orange on request", () => {
    expect(withOverrides(NOOK_DARK, { canvas: "#123456", nonsense: "#ffffff" }).canvas).toBe(0x123456);
    expect(diffColors(NOOK_DARK, "redGreen")).toEqual({ added: NOOK_DARK.added, removed: NOOK_DARK.removed });
    expect(diffColors(NOOK_DARK, "blueOrange").added).toBe(NOOK_DARK.blue);
  });

  it("reads a VS Code theme with comments and trailing commas", () => {
    expect(stripComments('{"a": "//x", /* c */ "b": [1,],}')).toBe('{"a": "//x",  "b": [1]}');
    const theme = importVSCodeTheme(`{
      // A light theme
      "name": "Sunny",
      "type": "light",
      "colors": { "editor.background": "#fdf6e3", "editor.foreground": "#657b83", "button.background": "#268bd2", },
    }`, "fallback");
    expect(theme).not.toBe("notJSON");
    if (typeof theme === "string") return;
    expect(theme.name).toBe("Sunny");
    expect(theme.dark).toBe(false);
    expect(theme.palette.canvas).toBe(0xfdf6e3);
    expect(theme.palette.accent).toBe(0x268bd2);
    expect(importVSCodeTheme("not json", "x")).toBe("notJSON");
    expect(importVSCodeTheme('{"colors": {}}', "x")).toBe("noColors");
    const all = allThemes([{ id: "c1", name: "Sunny", light: theme.palette }, { nope: true }]);
    expect(all.length).toBe(7);
    expect(all[all.length - 1].custom).toBe(true);
  });

  it("writes and reads a shared look in the Mac's format", () => {
    const source = '{"type":"dark","colors":{"editor.background":"#101418","editor.foreground":"#e0e0e0"}}';
    const theme = importVSCodeTheme(source, "Mine");
    if (typeof theme === "string") throw new Error(theme);
    const mine = { id: "custom-1", name: "Mine", source, dark: theme.palette };
    const file = lookFile({ accentHex: 0x8b7bff, theme: "dark", darkTheme: "custom-1", lightTheme: "paper", customThemes: [mine],
      colorOverrides: { dark: { canvas: "#000001" }, light: {} }, diffColors: "blueOrange", density: "compact", nookLook: { eyes: "dots" } });
    expect(file.format).toBe("nook-look");
    expect(file.accent).toBe("#8B7BFF");
    expect(file.themes).toHaveLength(1);
    // Someone without the theme gets it; someone with it keeps theirs.
    const fresh = readLook(JSON.stringify(file), [], { darkTheme: "nook", lightTheme: "nook" })!;
    expect(fresh.darkTheme).toBe("custom-1");
    expect(fresh.lightTheme).toBe("paper");
    expect(fresh.customThemes).toHaveLength(1);
    expect(fresh.accentHex).toBe(0x8b7bff);
    expect(fresh.colorOverrides?.dark.canvas).toBe("#000001");
    const again = readLook(JSON.stringify(file), [{ ...mine, id: "custom-9" }], { darkTheme: "nook", lightTheme: "nook" })!;
    expect(again.darkTheme).toBe("custom-9");
    expect(again.customThemes).toHaveLength(1);
    expect(readLook('{"format":"nooklook"}', [], { darkTheme: "nook", lightTheme: "nook" })).toBeNull();
    expect(readLook("nope", [], { darkTheme: "nook", lightTheme: "nook" })).toBeNull();
  });
});
