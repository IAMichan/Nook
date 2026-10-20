// Autocomplete Anywhere: the calls behind Settings › Autocomplete and the ghost-text window. Same shapes as the Rust
// structs (serde, camelCase).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type TriState = "inherit" | "on" | "off";
export type EscapeAction = "dismiss" | "pauseBriefly" | "offUntilAppSwitch";
export type EngineChoice = "local" | "brain";
export type LocalServer = "auto" | "ollama" | "lmstudio";

export interface AppRule {
  enabled: TriState;
  midLine: TriState;
  leaveTab: boolean;
  instructions: string;
}

export interface SiteRule {
  enabled: TriState;
  instructions: string;
}

export interface AutocompleteSettings {
  enabled: boolean;
  enabledByDefault: boolean;
  maxWords: number;
  midLine: boolean;
  eagerness: number;
  trailingSpace: boolean;
  punctuationWithWord: boolean;
  escape: EscapeAction;
  delayMilliseconds: number;
  engine: EngineChoice;
  localServer: LocalServer;
  model: string;
  windowContext: boolean;
  memoryContext: boolean;
  clipboardContext: boolean;
  instructions: string;
  apps: Record<string, AppRule>;
  sites: Record<string, SiteRule>;
  emoji: boolean;
  skinTone: number;
  acceptWord: string;
  acceptAll: string;
}

export interface AutocompleteStatus {
  state: "unsupported" | "off" | "checking" | "ready" | "paused" | "noModel" | "";
  detail: string;
  engine: string;
  local: boolean;
}

export interface Day {
  shown: number;
  accepted: number;
  takes: number;
  words: number;
  characters: number;
}

export interface StatsSummary {
  today: Day;
  week: Day;
  total: Day;
  acceptance: number;
  minutesSaved: number;
  streak: number;
  topApps: [string, { takes: number; words: number }][];
}

export interface SeenApp {
  id: string;
  name: string;
}

export interface AutocompleteView {
  status: AutocompleteStatus;
  stats: StatsSummary;
  seenApps: SeenApp[];
  offByDefault: string[];
  acceptKeys: string[];
  paused: boolean;
}

export interface PlaygroundResult {
  raw: string;
  shown: string | null;
  milliseconds: number;
  prompt: string;
  engine: string;
  confidence: boolean;
}

export interface EmojiChoice {
  emoji: string;
  name: string;
}

export interface EmojiChoices {
  query: string;
  choices: EmojiChoice[];
}

export interface PickerLayout {
  cell: number;
  padding: number;
  footer: number;
  columns: number;
  rows: number;
}

export type GhostEvent =
  | { kind: "text"; text: string; caretHeight: number }
  | { kind: "picker"; choices: EmojiChoice[]; selected: number; query: string; layout: PickerLayout };

export const autocomplete = {
  view: () => invoke<AutocompleteView>("autocomplete_view"),
  pause: (minutes: number | null) => invoke<AutocompleteView>("autocomplete_pause", { minutes }),
  resume: () => invoke<AutocompleteView>("autocomplete_resume"),
  resetStats: () => invoke<AutocompleteView>("autocomplete_reset_stats"),
  models: () => invoke<string[]>("autocomplete_models"),
  playground: (before: string, continuing: boolean) => invoke<PlaygroundResult | null>("autocomplete_playground", { before, continuing }),
  cancelPlayground: () => invoke<void>("autocomplete_playground_cancel"),
  emoji: (text: string) => invoke<EmojiChoices | null>("autocomplete_emoji", { text }),
};

export const autocompleteEvents = {
  onStatus: (cb: (s: AutocompleteStatus) => void): Promise<UnlistenFn> =>
    listen<AutocompleteStatus>("autocomplete-status", (e) => cb(e.payload)),
  onGhost: (cb: (e: GhostEvent) => void): Promise<UnlistenFn> => listen<GhostEvent>("autocomplete-ghost", (e) => cb(e.payload)),
};

/// An app id as compared: lowercase, without ".exe" (like `normalize_app` in Rust).
export function normalizeApp(id: string): string {
  const lower = id.trim().toLowerCase();
  return lower.endsWith(".exe") ? lower.slice(0, -4) : lower;
}

/// Whether an app is off by default (terminals, code editors, password managers); `*` matches any rest.
export function offByDefault(id: string, patterns: string[]): boolean {
  const app = normalizeApp(id);
  if (!app) return false;
  return patterns.some((p) => {
    const pattern = normalizeApp(p);
    return pattern.endsWith("*") ? app.startsWith(pattern.slice(0, -1)) : app === pattern;
  });
}

/// The rule for an app, whatever spelling its id has.
export function appRule(settings: AutocompleteSettings, id: string): AppRule {
  const wanted = normalizeApp(id);
  const key = Object.keys(settings.apps).find((k) => normalizeApp(k) === wanted);
  return key ? settings.apps[key] : { enabled: "inherit", midLine: "inherit", leaveTab: false, instructions: "" };
}

/// The settings with an app's rule changed; a rule back at its defaults goes.
export function withAppRule(settings: AutocompleteSettings, id: string, rule: AppRule): AutocompleteSettings {
  const wanted = normalizeApp(id);
  const apps = Object.fromEntries(Object.entries(settings.apps).filter(([k]) => normalizeApp(k) !== wanted));
  const isDefault = rule.enabled === "inherit" && rule.midLine === "inherit" && !rule.leaveTab && !rule.instructions.trim();
  if (!isDefault) apps[id] = rule;
  return { ...settings, apps };
}

/// The next word of a suggestion with the whitespace before it (CompletionSuggestion.nextChunk on the Mac). Without
/// attached punctuation the marks at the end of a word wait for the next press.
export function nextChunk(remaining: string, attachedPunctuation = false, trailingSpace = false): string {
  const match = /^\s*\S+/u.exec(remaining);
  if (!match) return "";
  let chunk = match[0];
  if (!attachedPunctuation) {
    const chars = Array.from(chunk);
    let last = -1;
    chars.forEach((c, i) => {
      if (/[\p{L}\p{N}]/u.test(c)) last = i;
    });
    if (last >= 0) chunk = chars.slice(0, last + 1).join("");
  }
  if (trailingSpace && remaining.slice(chunk.length).startsWith(" ")) chunk += " ";
  return chunk;
}
