// The window's colors as the Mac makes them (`NookPalette`, `NookColor`, `NookColorTheme`, `VSCodeThemeImport`,
// `NookDiffColors` in apps/macos/UI/Theme/NookPalette.swift): Nook's own palettes for dark and light, the built-in
// themes generated from a canvas, a text color and an accent, imported VS Code themes, colors set one by one, and the
// colors of a diff. `paletteVars` turns a palette into the CSS variables of app.css; Nook's own theme sets none, so
// app.css stays the source for it.

/** 0xRRGGBB. */
export type Hex = number;

/** The tokens a theme sets, named as on the Mac. */
export interface Palette {
  canvas: Hex; well: Hex; surface: Hex; composer: Hex; field: Hex; composerTray: Hex; graphite: Hex; smoke: Hex;
  rowRest: Hex; rowHover: Hex; rowSelected: Hex; bubble: Hex; chatTheirs: Hex; line: Hex; line2: Hex; hairline: Hex;
  border: Hex; separator: Hex; fieldStroke: Hex; paper: Hex; textStrong: Hex; textSecondary: Hex; textMuted: Hex;
  textTertiary: Hex; chatStamp: Hex; accent: Hex; blue: Hex; mint: Hex; mintSoft: Hex; amber: Hex; coral: Hex;
  coralSoft: Hex; violet: Hex; added: Hex; removed: Hex;
}

export type Token = keyof Palette;

/** Each token's CSS variable in app.css. */
export const TOKEN_VARS: Record<Token, string> = {
  canvas: "--canvas", well: "--well", surface: "--surface", composer: "--composer", field: "--field", composerTray: "--composer-tray",
  graphite: "--graphite", smoke: "--smoke", rowRest: "--row-rest", rowHover: "--row-hover", rowSelected: "--row-selected",
  bubble: "--bubble", chatTheirs: "--chat-theirs", line: "--line", line2: "--line2", hairline: "--hairline", border: "--border",
  separator: "--separator", fieldStroke: "--field-stroke", paper: "--paper", textStrong: "--text-strong", textSecondary: "--text2",
  textMuted: "--text-muted", textTertiary: "--text3", chatStamp: "--chat-stamp", accent: "--iris", blue: "--blue", mint: "--mint",
  mintSoft: "--mint-soft", amber: "--amber", coral: "--coral", coralSoft: "--coral-soft", violet: "--violet", added: "--added",
  removed: "--removed",
};

/** Nook in dark and in light: the values of app.css (`NookPalette.nookDark`, `.nookLight`). */
export const NOOK_DARK: Palette = {
  canvas: 0x000000, well: 0x0a0a0a, surface: 0x111111, composer: 0x111111, field: 0x0d0d0d, composerTray: 0x0d0d0d,
  graphite: 0x191a1d, smoke: 0x242424, rowRest: 0x0a0a0a, rowHover: 0x141415, rowSelected: 0x1c1c1e, bubble: 0x1e1e1e,
  chatTheirs: 0x1e1e1e, line: 0x1a1a1a, line2: 0x262626, hairline: 0x171717, border: 0x1a1a1a, separator: 0x1f1f1f,
  fieldStroke: 0x262626, paper: 0xf5f5f5, textStrong: 0xe5e5e5, textSecondary: 0xa1a1a1, textMuted: 0x8f8f8f, textTertiary: 0x8f8f8f,
  chatStamp: 0xa3b0ab, accent: 0xf4f3f7, blue: 0x5daacc, mint: 0x55d2a3, mintSoft: 0x5ee9b5, amber: 0xf0b65a, coral: 0xff6467,
  coralSoft: 0xfca5a5, violet: 0xb0a2e6, added: 0x00d492, removed: 0xff6467,
};
export const NOOK_LIGHT: Palette = {
  canvas: 0xfcfcfc, well: 0xfafafa, surface: 0xffffff, composer: 0xffffff, field: 0xffffff, composerTray: 0xffffff,
  graphite: 0xf4f4f5, smoke: 0xe4e4e7, rowRest: 0xfafafa, rowHover: 0xf4f4f5, rowSelected: 0xebebed, bubble: 0xebebed,
  chatTheirs: 0xf0f0f2, line: 0xe4e4e7, line2: 0xd4d4d8, hairline: 0xededef, border: 0xe4e4e7, separator: 0xe4e4e7,
  fieldStroke: 0xd4d4d8, paper: 0x18181b, textStrong: 0x27272a, textSecondary: 0x52525c, textMuted: 0x5c5c66, textTertiary: 0x62626c,
  chatStamp: 0x4e5a55, accent: 0x1e1e22, blue: 0x1447e6, mint: 0x006e4d, mintSoft: 0x007a55, amber: 0x973c00, coral: 0xc10007,
  coralSoft: 0xb91c1c, violet: 0x7008e7, added: 0x007a55, removed: 0xc10007,
};

// MARK: Color arithmetic (`NookColor`)

const byte = (v: number) => Math.round(Math.min(1, Math.max(0, v)) * 255);
const parts = (hex: Hex) => [((hex >> 16) & 0xff) / 255, ((hex >> 8) & 0xff) / 255, (hex & 0xff) / 255];

/** `from` moved `amount` (0…1) of the way to `to`. */
export function mix(from: Hex, to: Hex, amount: number): Hex {
  const a = parts(from), b = parts(to);
  return (byte(a[0] + (b[0] - a[0]) * amount) << 16) | (byte(a[1] + (b[1] - a[1]) * amount) << 8) | byte(a[2] + (b[2] - a[2]) * amount);
}

/** WCAG relative luminance, 0 (black) to 1 (white). */
export function luminance(hex: Hex): number {
  const ch = (c: number) => (c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  const [r, g, b] = parts(hex);
  return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
}

/** WCAG contrast ratio, 1 to 21. */
export function contrast(a: Hex, b: Hex): number {
  const la = luminance(a), lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** "#RGB", "#RRGGBB" or "#RRGGBBAA"; a color with alpha is laid over `background`. */
export function parseColor(text: unknown, background?: Hex): Hex | null {
  if (typeof text !== "string") return null;
  let t = text.trim();
  if (!t.startsWith("#")) return null;
  t = t.slice(1);
  if (t.length === 3 || t.length === 4) t = [...t].map((c) => c + c).join("");
  if ((t.length !== 6 && t.length !== 8) || !/^[0-9a-f]+$/i.test(t)) return null;
  const rgb = parseInt(t.slice(0, 6), 16);
  if (t.length === 6) return rgb;
  const alpha = parseInt(t.slice(6), 16) / 255;
  return alpha >= 1 ? rgb : mix(background ?? rgb, rgb, alpha);
}

export const cssHex = (hex: Hex) => `#${hex.toString(16).padStart(6, "0")}`;

// MARK: Palettes

const TEXT: Token[] = ["textStrong", "textSecondary", "textMuted", "textTertiary"];
const READING: Token[] = ["canvas", "well", "surface", "field", "graphite", "smoke", "rowSelected"];

/** Every grey text moved toward `paper` until it reads at WCAG AA (4.5:1) on every reading surface (`readable()`). */
export function readable(palette: Palette, minimum = 4.5): Palette {
  const out = { ...palette };
  for (const token of TEXT) {
    let value = palette[token];
    let amount = 0;
    while (amount < 1 && READING.some((s) => contrast(value, palette[s]) < minimum)) {
      amount += 0.05;
      value = mix(palette[token], palette.paper, amount);
    }
    out[token] = value;
  }
  return out;
}

/** A palette from a canvas, its text and an accent, the surfaces stepped from the canvas toward the text (`generated`). */
export function generated(dark: boolean, canvas: Hex, text: Hex, accent: Hex, link?: Hex): Palette {
  const step = (amount: number) => mix(canvas, text, amount);
  const p: Palette = { ...(dark ? NOOK_DARK : NOOK_LIGHT) };
  p.canvas = canvas;
  p.well = dark ? step(0.025) : mix(canvas, 0x000000, 0.035);
  p.surface = dark ? step(0.06) : mix(canvas, 0xffffff, 0.6);
  p.composer = p.surface;
  p.field = dark ? step(0.05) : mix(canvas, 0x000000, 0.02);
  p.composerTray = p.field;
  p.graphite = step(dark ? 0.09 : 0.05);
  p.smoke = step(dark ? 0.13 : 0.085);
  p.rowRest = step(dark ? 0.03 : 0.025);
  p.rowHover = step(dark ? 0.08 : 0.05);
  p.rowSelected = step(dark ? 0.13 : 0.09);
  p.bubble = step(dark ? 0.1 : 0.055);
  p.chatTheirs = step(dark ? 0.12 : 0.06);
  p.line = step(dark ? 0.1 : 0.08);
  p.line2 = step(dark ? 0.16 : 0.14);
  p.hairline = p.line;
  p.border = step(dark ? 0.11 : 0.1);
  p.separator = step(dark ? 0.14 : 0.12);
  p.fieldStroke = step(dark ? 0.15 : 0.16);
  p.paper = text;
  p.textStrong = step(0.88);
  p.textSecondary = step(0.68);
  p.textMuted = step(0.64);
  p.textTertiary = step(0.62);
  p.chatStamp = step(0.66);
  p.accent = accent;
  if (link !== undefined) p.blue = link;
  return readable(p);
}

/** Every grey text a step closer to `paper`: for the high-contrast theme (`raised(by:)`). */
function raised(p: Palette, amount: number): Palette {
  return {
    ...p,
    textStrong: mix(p.textStrong, p.paper, amount * 2), textSecondary: mix(p.textSecondary, p.paper, amount * 2),
    textMuted: mix(p.textMuted, p.paper, amount * 2), textTertiary: mix(p.textTertiary, p.paper, amount * 2),
    border: mix(p.border, p.paper, amount), separator: mix(p.separator, p.paper, amount), fieldStroke: mix(p.fieldStroke, p.paper, amount),
  };
}

// MARK: Themes

export interface ColorTheme {
  id: string;
  name: string;
  dark?: Palette;
  light?: Palette;
  /** Imported by you, so it can be removed. */
  custom?: boolean;
  /** An imported theme's VS Code source, so a shared look carries it as the Mac's does. */
  source?: string;
}

/** The built-in themes, in the Mac's order (`NookColorTheme.builtIn`); names are translated where they are shown. */
export const BUILT_IN: ColorTheme[] = [
  { id: "nook", name: "Nook", dark: NOOK_DARK, light: NOOK_LIGHT },
  { id: "warm", name: "Warm", dark: generated(true, 0x1f1e1b, 0xf1eee6, 0xe08a66, 0x9dbceb), light: generated(false, 0xfaf9f5, 0x2b2924, 0xb5542f, 0x2f5f9e) },
  { id: "mono", name: "Mono", dark: generated(true, 0x101010, 0xededed, 0xededed), light: generated(false, 0xf6f6f6, 0x141414, 0x141414) },
  { id: "midnight", name: "Midnight", dark: generated(true, 0x0b0e14, 0xe6eaf2, 0x8aa8f8, 0x8ab4f8), light: generated(false, 0xf4f6fa, 0x111827, 0x2f5bd3, 0x2457c5) },
  { id: "paper", name: "Paper", dark: generated(true, 0x15130f, 0xefe8dc, 0xe3b56f, 0xa8c0e8), light: generated(false, 0xf7f3ea, 0x1f1a12, 0x7a4e12, 0x2e5a9e) },
  {
    id: "contrast", name: "High contrast",
    dark: raised(generated(true, 0x000000, 0xffffff, 0xffffff, 0x9cc2ff), 0.12), light: raised(generated(false, 0xffffff, 0x000000, 0x000000, 0x1747a6), 0.12),
  },
];

/** Built-in and imported themes; an imported entry that does not hold a palette is skipped. */
export function allThemes(custom: unknown[] | undefined): ColorTheme[] {
  const valid = (custom ?? []).filter((t): t is ColorTheme => !!t && typeof t === "object" && typeof (t as ColorTheme).id === "string" && (!!(t as ColorTheme).dark || !!(t as ColorTheme).light));
  return [...BUILT_IN, ...valid.map((t) => ({ ...t, custom: true }))];
}

/** The chosen theme's palette for the look in effect; Nook's own when it is gone or has none for this look. */
export function themePalette(themes: ColorTheme[], id: string | undefined, dark: boolean): Palette {
  const theme = themes.find((t) => t.id === id);
  return (dark ? theme?.dark : theme?.light) ?? (dark ? NOOK_DARK : NOOK_LIGHT);
}

/** The palette with the colors set by hand laid over it ("#rrggbb" per token). */
export function withOverrides(palette: Palette, overrides: Record<string, string> | undefined): Palette {
  const out = { ...palette };
  for (const [token, value] of Object.entries(overrides ?? {})) {
    const hex = parseColor(value);
    if (hex !== null && token in TOKEN_VARS) out[token as Token] = hex;
  }
  return out;
}

export type DiffColors = "redGreen" | "blueOrange";

/** Added and removed in a diff (`NookDiffColors`): green and red, or blue and an orange away from it in hue. */
export function diffColors(palette: Palette, choice: string | undefined): { added: Hex; removed: Hex } {
  return choice === "blueOrange"
    ? { added: palette.blue, removed: mix(palette.amber, palette.coral, 0.45) }
    : { added: palette.added, removed: palette.removed };
}

/** The CSS variables to set on the window: none for Nook's own palette untouched, every token otherwise. */
export function paletteVars(palette: Palette, base: Palette): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const token of Object.keys(TOKEN_VARS) as Token[]) {
    if (palette[token] !== base[token]) vars[TOKEN_VARS[token]] = cssHex(palette[token]);
  }
  return vars;
}

// MARK: VS Code themes (`VSCodeThemeImport`)

/** JSON with comments and trailing commas, as VS Code allows, made strict; strings stay untouched. */
export function stripComments(source: string): string {
  let out = "";
  let i = 0;
  let inString = false;
  while (i < source.length) {
    const c = source[i];
    if (inString) {
      out += c;
      if (c === "\\" && i + 1 < source.length) { out += source[i + 1]; i += 2; continue; }
      if (c === "\"") inString = false;
      i += 1;
      continue;
    }
    if (c === "\"") { inString = true; out += c; i += 1; continue; }
    if (c === "/" && source[i + 1] === "/") { while (i < source.length && source[i] !== "\n") i += 1; continue; }
    if (c === "/" && source[i + 1] === "*") {
      i += 2;
      while (i + 1 < source.length && !(source[i] === "*" && source[i + 1] === "/")) i += 1;
      i += 2;
      continue;
    }
    if (c === ",") {
      let j = i + 1;
      while (j < source.length && /\s/.test(source[j])) j += 1;
      if (source[j] === "}" || source[j] === "]") { i += 1; continue; }
    }
    out += c;
    i += 1;
  }
  return out;
}

export type ImportFailure = "notJSON" | "noColors";

/** A VS Code color theme as a Nook theme: the editor is the canvas, the side bar the surface, the inputs the fields,
 *  the lists the rows, the foregrounds the text, the button or focus color the accent, the terminal's colors the state. */
export function importVSCodeTheme(source: string, fallbackName: string): { name: string; dark: boolean; palette: Palette } | ImportFailure {
  let object: Record<string, unknown>;
  try {
    object = JSON.parse(stripComments(source));
  } catch {
    return "notJSON";
  }
  if (!object || typeof object !== "object") return "notJSON";
  const colors = object.colors as Record<string, unknown> | undefined;
  if (!colors || typeof colors !== "object" || !Object.keys(colors).length) return "noColors";
  const type = typeof object.type === "string" ? object.type.toLowerCase() : "";
  const editor = parseColor(colors["editor.background"]);
  const dark = type.includes("light") ? false : type.includes("dark") || type === "hc" ? true : luminance(editor ?? 0) < 0.4;
  const base = dark ? NOOK_DARK : NOOK_LIGHT;
  const canvas = editor ?? base.canvas;
  const color = (...keys: string[]) => {
    for (const k of keys) {
      const v = parseColor(colors[k], canvas);
      if (v !== null) return v;
    }
    return null;
  };
  const text = color("editor.foreground", "foreground") ?? base.paper;
  const accent = color("button.background", "focusBorder", "activityBarBadge.background", "textLink.foreground") ?? base.accent;
  const p = generated(dark, canvas, text, accent, color("textLink.foreground") ?? undefined);
  const set = (value: Hex | null, ...tokens: Token[]) => { if (value !== null) for (const t of tokens) p[t] = value; };
  set(color("sideBar.background", "panel.background"), "surface", "composer");
  set(color("editorWidget.background", "dropdown.background"), "graphite");
  set(color("input.background"), "field", "composerTray");
  set(color("input.border"), "fieldStroke");
  set(color("sideBar.border", "panel.border", "editorGroup.border"), "border");
  set(color("list.hoverBackground"), "rowHover");
  set(color("list.activeSelectionBackground", "list.inactiveSelectionBackground"), "rowSelected", "smoke");
  set(color("sideBar.foreground"), "textStrong");
  set(color("descriptionForeground"), "textSecondary");
  set(color("terminal.ansiGreen", "gitDecoration.addedResourceForeground"), "mint", "mintSoft", "added");
  set(color("terminal.ansiYellow", "editorWarning.foreground"), "amber");
  set(color("terminal.ansiRed", "errorForeground", "editorError.foreground"), "coral", "coralSoft", "removed");
  set(color("terminal.ansiMagenta"), "violet");
  const named = typeof object.name === "string" && object.name.trim() ? object.name.trim() : fallbackName;
  return { name: named, dark, palette: readable(p) };
}

// MARK: Sharing the look (`NookLookShare`)

/** A `.nooklook` file as the Mac writes it, so a look moves between the Mac and Windows: the accent, the appearance, per
 *  appearance its theme and the colors set by hand, the imported themes in use (as their VS Code source), the diff
 *  colors, the density and Nook's face. */
export interface LookFile {
  format: "nook-look";
  version: 1;
  accent?: string;
  appearance?: string;
  diffColors?: string;
  density?: string;
  dark: { theme?: string; colors: Record<string, string> };
  light: { theme?: string; colors: Record<string, string> };
  themes: { id: string; name: string; source: string }[];
  nook?: Record<string, unknown>;
}

/** What the window keeps of a look (the fields of Settings it sets). */
export interface Look {
  accentHex?: number;
  theme?: string;
  darkTheme?: string;
  lightTheme?: string;
  customThemes?: ColorTheme[];
  colorOverrides?: { dark: Record<string, string>; light: Record<string, string> };
  diffColors?: string;
  density?: string;
  nookLook?: Record<string, unknown>;
}

/** The file for the look in use; only the imported themes in use go along. */
export function lookFile(look: Required<Omit<Look, "nookLook">> & { nookLook?: Record<string, unknown> }): LookFile {
  const used = look.customThemes.filter((t) => t.source && (t.id === look.darkTheme || t.id === look.lightTheme));
  return {
    format: "nook-look", version: 1, accent: cssHex(look.accentHex & 0xffffff).toUpperCase(), appearance: look.theme,
    diffColors: look.diffColors, density: look.density,
    dark: { theme: look.darkTheme, colors: look.colorOverrides.dark }, light: { theme: look.lightTheme, colors: look.colorOverrides.light },
    themes: used.map((t) => ({ id: t.id, name: t.name, source: t.source! })), nook: look.nookLook,
  };
}

/** Reads a look file; anything that is not one (another JSON, a VS Code theme) is null. `existing` are your imported
 *  themes: a theme you already have (the same source) is reused, one whose id you use for another gets a new id, and a
 *  theme id that is neither built in nor in the file keeps yours (`themes(mergedInto:)`). */
export function readLook(text: string, existing: ColorTheme[], current: { darkTheme: string; lightTheme: string }): Look | null {
  let raw: Record<string, unknown>;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object" || raw.format !== "nook-look") return null;
  const out: Look = {};
  const accent = parseColor(raw.accent);
  if (accent !== null) out.accentHex = accent;
  if (raw.appearance === "system" || raw.appearance === "light" || raw.appearance === "dark") out.theme = raw.appearance;
  if (raw.diffColors === "redGreen" || raw.diffColors === "blueOrange") out.diffColors = raw.diffColors;
  if (raw.density === "compact" || raw.density === "comfortable" || raw.density === "spacious") out.density = raw.density;
  if (raw.nook && typeof raw.nook === "object") out.nookLook = raw.nook as Record<string, unknown>;
  const side = (key: "dark" | "light") => {
    const v = (raw[key] ?? {}) as { theme?: unknown; colors?: Record<string, unknown> };
    const colors: Record<string, string> = {};
    for (const [id, value] of Object.entries(v.colors ?? {})) {
      const hex = parseColor(value);
      if (hex !== null) colors[id] = cssHex(hex);
    }
    return { theme: typeof v.theme === "string" ? v.theme : undefined, colors };
  };
  const dark = side("dark"), light = side("light");
  out.colorOverrides = { dark: dark.colors, light: light.colors };
  const result = [...existing];
  const renamed: Record<string, string> = {};
  const files = Array.isArray(raw.themes) ? (raw.themes as { id?: unknown; name?: unknown; source?: unknown }[]) : [];
  for (const t of files) {
    if (typeof t.id !== "string" || typeof t.source !== "string" || (t.id !== dark.theme && t.id !== light.theme)) continue;
    const same = result.find((r) => r.source === t.source);
    if (same) { renamed[t.id] = same.id; continue; }
    const imported = importVSCodeTheme(t.source, typeof t.name === "string" ? t.name : t.id);
    if (typeof imported === "string") continue;
    let id = t.id;
    const taken = () => result.some((r) => r.id === id) || BUILT_IN.some((b) => b.id === id);
    while (taken()) id = `custom-${Math.random().toString(36).slice(2, 10)}`;
    renamed[t.id] = id;
    result.push({ id, name: typeof t.name === "string" ? t.name : imported.name, source: t.source, [imported.dark ? "dark" : "light"]: imported.palette });
  }
  const resolve = (id: string | undefined, mine: string) => (id === undefined ? mine : renamed[id] ?? (BUILT_IN.some((b) => b.id === id) ? id : mine));
  out.darkTheme = resolve(dark.theme, current.darkTheme);
  out.lightTheme = resolve(light.theme, current.lightTheme);
  out.customThemes = result;
  return out;
}
