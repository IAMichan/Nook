// The interface language of the Tauri app, the same five as the Mac (`AppLanguage` in apps/macos/Core/I18n.swift):
// English (the default), Dutch, German, French, and Spanish, from the `appLanguage` setting.
//
// Write each visible string as `tr("Nederlands", "English")`. Dutch and English are written inline; German, French,
// and Spanish come from the catalogs in `./i18n/*.ts`, keyed by the English text. Values go in `{name}` placeholders,
// never in a template literal: `tr("{n} rondes", "{n} rounds", { n })`. `i18n.test.ts` checks that every English text
// has all three translations with the same placeholders. `tr` reads the setting, so a view redraws when it changes.
import { nook } from "./state.svelte";
import { catalog, type Entry } from "./i18n/catalog";

export type AppLanguage = "en" | "nl" | "de" | "fr" | "es";

/// The languages in the order the Mac lists them, each in its own language.
export const APP_LANGUAGES: { code: AppLanguage; name: string }[] = [
  { code: "en", name: "English" },
  { code: "nl", name: "Nederlands" },
  { code: "de", name: "Deutsch" },
  { code: "fr", name: "Français" },
  { code: "es", name: "Español" },
];

const LOCALES: Record<AppLanguage, string> = { en: "en-GB", nl: "nl-NL", de: "de-DE", fr: "fr-FR", es: "es-ES" };

export function isAppLanguage(v: unknown): v is AppLanguage {
  return typeof v === "string" && v in LOCALES;
}

/// Like the Mac: the system's preferred language when Nook speaks it, otherwise English.
export function systemLanguage(): AppLanguage {
  const preferred = (typeof navigator !== "undefined" ? navigator.language : "en").slice(0, 2).toLowerCase();
  return isAppLanguage(preferred) ? preferred : "en";
}

export function appLanguage(): AppLanguage {
  const v = nook.settings?.appLanguage;
  return isAppLanguage(v) ? v : systemLanguage();
}

/// True unless the interface is Dutch: content that only exists in Dutch and English (a game's coaching text, a
/// compact notice) falls back to English for German, French, and Spanish, the same fallback `tr` uses.
export const english = () => appLanguage() !== "nl";

/// The BCP 47 locale for dates and numbers in the interface language.
export const locale = () => LOCALES[appLanguage()];

export type Vars = Record<string, string | number>;

/// Fills `{name}` placeholders.
export function fill(text: string, vars?: Vars): string {
  if (!vars) return text;
  return text.replace(/\{(\w+)\}/g, (all, k: string) => (k in vars ? String(vars[k]) : all));
}

/// The text for a language, from its Dutch and English source. Pure, so tests can call it without settings.
export function translate(lang: AppLanguage, nl: string, en: string): string {
  if (lang === "nl") return nl;
  if (lang === "en") return en;
  const entry: Entry | undefined = catalog[en];
  return entry?.[lang] ?? en;
}

export function tr(nl: string, en: string, vars?: Vars): string {
  return fill(translate(appLanguage(), nl, en), vars);
}
