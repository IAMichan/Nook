// The Tauri theme mirrors the Mac's `NookTheme` 1:1: this test reads NookPalette.swift and NookTheme.swift from the
// repository and the variables from app.css, and fails when a color, radius, spacing step, text style or motion
// duration differs. Change both sides together; a deliberate difference goes in `deviations` with its reason.
import { describe, expect, it } from "vitest";
import palette from "../../../macos/UI/Theme/NookPalette.swift?raw";
import theme from "../../../macos/UI/Theme/NookTheme.swift?raw";

// Vitest hands CSS imports over empty, so app.css is read from disk (Node's fs, without its type definitions: the app
// is typed for the browser).
const fs = (await import(/* @vite-ignore */ ["node", "fs"].join(":"))) as { readFileSync: (path: URL, encoding: "utf8") => string };
const css = fs.readFileSync(new URL("../app.css", import.meta.url), "utf8");

/** The variables of one CSS block (`:root {` or `:root[data-theme="light"] {`). */
function cssBlock(selector: string): Record<string, string> {
  const start = css.indexOf(`${selector} {`);
  const body = css.slice(start, css.indexOf("\n}", start));
  return Object.fromEntries([...body.matchAll(/--([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim().toLowerCase()]));
}

/** The hex colors of one `NookPalette(...)` literal. */
function swiftPalette(name: string): Record<string, string> {
  const start = palette.indexOf(`static let ${name} = NookPalette(`);
  const body = palette.slice(start, palette.indexOf(")\n", start));
  return Object.fromEntries([...body.matchAll(/(\w+): 0x([0-9A-Fa-f]{6})/g)].map((m) => [m[1], `#${m[2].toLowerCase()}`]));
}

// NookPalette field → CSS variable.
const colorNames: Record<string, string> = {
  canvas: "canvas", well: "well", surface: "surface", field: "field", graphite: "graphite", smoke: "smoke",
  rowRest: "row-rest", rowHover: "row-hover", rowSelected: "row-selected", bubble: "bubble", chatMine: "chat-mine",
  chatTheirs: "chat-theirs", line: "line", line2: "line2", hairline: "hairline", border: "border", separator: "separator",
  fieldStroke: "field-stroke", paper: "paper", textStrong: "text-strong", textSecondary: "text2", textMuted: "text-muted",
  textTertiary: "text3", chatStamp: "chat-stamp", blue: "blue", mint: "mint", mintSoft: "mint-soft", amber: "amber",
  coral: "coral", coralSoft: "coral-soft", violet: "violet", music: "music", added: "added", removed: "removed",
  accent: "iris", composer: "composer", composerTray: "composer-tray", menu: "menu",
  syntaxKeyword: "syntax-keyword", syntaxString: "syntax-string", syntaxComment: "syntax-comment",
  syntaxNumber: "syntax-number", syntaxType: "syntax-type", syntaxProperty: "syntax-property", syntaxTag: "syntax-tag",
  syntaxAttribute: "syntax-attribute",
};

// Differences on purpose, with why (also in docs/TAURI.md).
const deviations: Record<string, string> = {
  // The Mac keeps menus dark in light mode because they are drawn with their own text colors; the Tauri menus use the
  // theme's text color, so a dark menu would put dark text on dark.
  "light.menu": "#ffffff",
};

describe("theme tokens mirror NookTheme", () => {
  for (const [name, selector] of [["nookDark", ":root"], ["nookLight", ':root[data-theme="light"]']] as const) {
    it(`colors of ${name}`, () => {
      const swift = swiftPalette(name);
      const vars = cssBlock(selector);
      const key = name === "nookDark" ? "dark" : "light";
      const differ = Object.entries(colorNames)
        .filter(([field]) => field in swift)
        .map(([field, v]) => [v, deviations[`${key}.${v}`] ?? swift[field], vars[v]] as const)
        .filter(([, want, got]) => want !== got)
        .map(([v, want, got]) => `--${v}: want ${want}, got ${got}`);
      expect(Object.keys(swift).length).toBeGreaterThan(40);
      expect(differ).toEqual([]);
    });
  }

  const root = cssBlock(":root");
  const kebab = (s: string) => s.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
  const enumBody = (name: string) => {
    const start = theme.indexOf(`enum ${name} {`);
    return theme.slice(start, theme.indexOf("\n    }", start));
  };

  it("radii", () => {
    const radii = [...enumBody("Radius").matchAll(/static let (\w+): CGFloat = ([\d.]+)/g)];
    expect(radii.length).toBeGreaterThan(8);
    expect(radii.map(([, n, v]) => `${kebab(n)}: ${root[`radius-${kebab(n)}`]}`)).toEqual(radii.map(([, n, v]) => `${kebab(n)}: ${v}px`));
  });

  it("spacing", () => {
    const steps = [...enumBody("Spacing").matchAll(/static let \w+: CGFloat = (\d+)/g)].map((m) => m[1]);
    expect(steps).toEqual(["2", "4", "6", "8", "12", "16", "24", "32", "48"]);
    expect(steps.map((s) => root[`space-${s}`])).toEqual(steps.map((s) => `${s}px`));
  });

  it("text styles", () => {
    const weights: Record<string, number> = { regular: 400, medium: 500, semibold: 600, bold: 700 };
    const styles = [...enumBody("TextStyle").matchAll(/static var (\w+): Font \{ NookTheme\.textFont\(([\d.]+)(?:, \.(\w+))?(?:, design: \.(\w+))?\) \}/g)];
    expect(styles.length).toBeGreaterThan(8);
    for (const [, name, size, weight, design] of styles) {
      // `strong` shares its name with the --text-strong color, so its style is --text-emphasis.
      const v = root[name === "strong" ? "text-emphasis" : `text-${name}`];
      expect(v, name).toBeDefined();
      const [w, rest] = [v.split(" ")[0], v.split(" ")[1]];
      expect(`${name}: ${w} ${rest.split("/")[0]}${design === "monospaced" ? " mono" : ""}`).toBe(
        `${name}: ${weights[weight ?? "regular"]} ${size}px${design === "monospaced" ? " mono" : ""}`);
      if (design === "monospaced") expect(v).toContain("var(--mono)");
    }
  });

  it("motion", () => {
    const motion = enumBody("Motion");
    const seconds = (src: string, n: string) => Number(src.match(new RegExp(`static let ${n} = Animation\\.\\w+\\(duration: ([\\d.]+)`))?.[1]) * 1000;
    for (const n of ["quick", "standard", "slow", "panel", "list", "reduced"]) {
      expect(root[`motion-${n}`], n).toMatch(new RegExp(`^${seconds(motion, n)}ms `));
    }
    for (const [n, v] of [["hover", "motion-hover"], ["tipFade", "motion-tip"], ["reveal", "motion-reveal"]]) {
      expect(root[v], n).toMatch(new RegExp(`^${seconds(theme, n)}ms `));
    }
    expect(root["tooltip-max-width"]).toBe(`${theme.match(/tooltipMaxWidth: CGFloat = (\d+)/)![1]}px`);
  });
});
