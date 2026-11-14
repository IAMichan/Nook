// Settings › Appearance on the page: System, Light or Dark (`appearanceMode` on the Mac), the density, and the accent.
// The light palette itself lives in app.css under `:root[data-theme="light"]`; this file only decides which applies.
import type { Settings } from "./types";

export type ThemeSetting = Settings["theme"];
export type Density = Settings["density"];

export const THEMES: ThemeSetting[] = ["system", "light", "dark"];
export const DENSITIES: Density[] = ["compact", "comfortable", "spacious"];

/// The accent swatches (the first is Nook's own soft white, which turns near-black in light).
export const ACCENTS = [0xf4f3f7, 0x8b7bff, 0x46e0a6, 0xffb84d, 0xff8a5b, 0x5ab8ff, 0xff6bb5];

/// Nook's accent in light (`NookPalette.nookLight.accent`).
export const LIGHT_ACCENT = 0x1e1e22;

/// The look that applies: System follows the operating system, anything unknown stays dark (as old settings do).
export function resolveTheme(setting: string | undefined, systemDark: boolean): "light" | "dark" {
  if (setting === "light") return "light";
  if (setting === "system") return systemDark ? "dark" : "light";
  return "dark";
}

function luminance(hex: number): number {
  const ch = (v: number) => {
    const c = (v & 0xff) / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * ch(hex >> 16) + 0.7152 * ch(hex >> 8) + 0.0722 * ch(hex);
}

/// The accent drawn on a canvas: a near-white accent would vanish on the light canvas, so there it becomes Nook's
/// light accent; every colored accent stays as chosen.
export function themeAccent(hex: number, look: "light" | "dark"): number {
  return look === "light" && luminance(hex) > 0.7 ? LIGHT_ACCENT : hex;
}

export function isDensity(v: unknown): v is Density {
  return typeof v === "string" && (DENSITIES as string[]).includes(v);
}
