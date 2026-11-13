// The counterpart of I18nCoverageTests on the Mac: every visible string in the interface goes through `tr(nl, en)`,
// and every English text has German, French, and Spanish with the same `{placeholders}`.
import { describe, expect, it } from "vitest";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { catalog } from "./i18n/catalog";
import { fill, translate } from "./i18n.svelte";

const SRC = join(__dirname, "..");

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name === "i18n" ? [] : files(path);
    return /\.(svelte|ts)$/.test(name) && !name.endsWith(".test.ts") ? [path] : [];
  });
}

const STR = String.raw`("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\x60(?:[^\x60\\]|\\.)*\x60)`;
const CALL = new RegExp(String.raw`\btr\(\s*` + STR + String.raw`\s*,\s*` + STR, "g");

function unquote(lit: string): string {
  const body = lit.slice(1, -1);
  return body.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|.)/g, (_, e: string) => {
    if (e.startsWith("u{")) return String.fromCodePoint(parseInt(e.slice(2, -1), 16));
    if (e.startsWith("u")) return String.fromCharCode(parseInt(e.slice(1), 16));
    return e === "n" ? "\n" : e === "t" ? "\t" : e;
  });
}

type Use = { file: string; nl: string; en: string; raw: string };

const uses: Use[] = files(SRC).flatMap((file) => {
  const text = readFileSync(file, "utf8");
  return [...text.matchAll(CALL)].map((m) => ({ file: file.slice(SRC.length + 1), nl: unquote(m[1]), en: unquote(m[2]), raw: m[1] + m[2] }));
});

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(",");

describe("i18n", () => {
  it("finds the interface's strings", () => {
    expect(uses.length).toBeGreaterThan(400);
  });

  it("never builds a translated string from a template literal", () => {
    const bad = uses.filter((u) => u.raw.includes("${")).map((u) => `${u.file}: ${u.en}`);
    expect(bad).toEqual([]);
  });

  it("has Dutch and English with the same placeholders", () => {
    const bad = uses.filter((u) => placeholders(u.nl) !== placeholders(u.en)).map((u) => `${u.file}: ${u.nl} | ${u.en}`);
    expect(bad).toEqual([]);
  });

  it("has German, French, and Spanish for every English text", () => {
    const missing = [...new Set(uses.filter((u) => !catalog[u.en]).map((u) => `${u.file}: ${u.en}`))];
    expect(missing).toEqual([]);
  });

  it("keeps the placeholders in every translation", () => {
    const bad = Object.entries(catalog).flatMap(([en, e]) =>
      (["de", "fr", "es"] as const).filter((l) => placeholders(e[l]) !== placeholders(en)).map((l) => `${l}: ${en} → ${e[l]}`),
    );
    expect(bad).toEqual([]);
  });

  it("translates through the catalog and falls back to English", () => {
    const [en, entry] = Object.entries(catalog)[0] ?? ["Settings", { de: "Einstellungen", fr: "Réglages", es: "Ajustes" }];
    expect(translate("nl", "Instellingen", en)).toBe("Instellingen");
    expect(translate("en", "Instellingen", en)).toBe(en);
    if (catalog[en]) expect(translate("de", "x", en)).toBe(entry.de);
    expect(translate("fr", "x", "A text nobody translated")).toBe("A text nobody translated");
    expect(fill("{n} rounds", { n: 3 })).toBe("3 rounds");
  });
});
