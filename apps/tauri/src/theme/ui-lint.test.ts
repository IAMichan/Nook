// The Svelte side of the Mac's `UIConsistencyTests`: every view takes its colors, type and radii from the theme
// (app.css, mirroring `NookTheme`), never inline values. Outside `<script>`, a .svelte file may not write a color
// literal (#hex, rgb(), hsl()), a font size in px, or a radius in px (0 and the 999px pill excepted).
//
// Older files still have some; `ui-baseline.json` holds how many each may keep. A file may only go down: more than its
// count, or any in a new file, fails. After cleaning up, shrink the baseline with
//   UPDATE_UI_BASELINE=1 npx vitest run src/theme/ui-lint.test.ts
// (it never raises a count). The phone look inside the companion (`.phone`, the iPhone's own sizes) is counted too.
import { describe, expect, it } from "vitest";
import baselineText from "./ui-baseline.json?raw";

const sources = import.meta.glob<string>(["../**/*.svelte"], { query: "?raw", import: "default", eager: true });
type Counts = { color: number; font: number; radius: number };
const baseline: Record<string, Counts> = JSON.parse(baselineText);
// Node's own modules, reached without its type definitions (the app is typed for the browser).
const env = (globalThis as { process?: { env: Record<string, string | undefined> } }).process?.env ?? {};

/** What a file writes by hand, outside its scripts. */
export function inlineValues(text: string): Counts {
  const body = text.replace(/<script[\s\S]*?<\/script>/g, "").replace(/<!--[\s\S]*?-->/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
  const color = (body.match(/#[0-9a-fA-F]{3,8}\b(?![\w-])|\b(?:rgba?|hsla?)\(/g) ?? []).length;
  const font = (body.match(/font(?:-size)?\s*:[^;"}]*?\b\d+(?:\.\d+)?px/g) ?? []).length;
  const radius = (body.match(/(?:border-[\w-]*radius|radius)\s*:[^;"}]*/g) ?? [])
    .filter((decl) => /\b(?!0px)(?!999px)\d+(?:\.\d+)?px/.test(decl)).length;
  return { color, font, radius };
}

const name = (path: string) => path.replace(/^\.\.\//, "src/");

describe("inline colors, font sizes and radii", () => {
  const now = Object.fromEntries(Object.entries(sources).map(([p, t]) => [name(p), inlineValues(t)]));

  it("only go down", async () => {
    const worse: string[] = [];
    for (const [file, c] of Object.entries(now)) {
      const allowed = baseline[file] ?? { color: 0, font: 0, radius: 0 };
      for (const k of ["color", "font", "radius"] as const) {
        if (c[k] > allowed[k]) worse.push(`${file}: ${c[k]} inline ${k} (allowed ${allowed[k]}); use the theme's variables`);
      }
    }
    if (env.UPDATE_UI_BASELINE) {
      const next: Record<string, Counts> = {};
      for (const [file, c] of Object.entries(now).sort(([a], [b]) => a.localeCompare(b))) {
        const old = baseline[file] ?? { color: 0, font: 0, radius: 0 };
        const kept = { color: Math.min(c.color, old.color), font: Math.min(c.font, old.font), radius: Math.min(c.radius, old.radius) };
        if (kept.color || kept.font || kept.radius) next[file] = kept;
      }
      const fs = (await import(/* @vite-ignore */ ["node", "fs"].join(":"))) as { writeFileSync: (path: URL, text: string) => void };
      fs.writeFileSync(new URL("./ui-baseline.json", import.meta.url), `${JSON.stringify(next, null, 1)}\n`);
    }
    expect(worse).toEqual([]);
  });

  it("recognizes what it counts", () => {
    expect(inlineValues(`<div style="color: #fff"></div><style>.a { font-size: 12px; border-radius: 6px; background: rgba(0,0,0,.4) }</style>`))
      .toEqual({ color: 2, font: 1, radius: 1 });
    expect(inlineValues(`<style>.a { font: var(--text-body); border-radius: var(--radius-card); color: var(--paper); border-radius: 999px; }</style>`))
      .toEqual({ color: 0, font: 0, radius: 0 });
    expect(inlineValues(`<script>const c = "#ffffff";</script><p>#1 issue</p>`)).toEqual({ color: 0, font: 0, radius: 0 });
  });
});
