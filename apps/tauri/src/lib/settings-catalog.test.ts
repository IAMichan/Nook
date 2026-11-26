import { describe, expect, it } from "vitest";
import catalogSource from "../../core/src/settings_catalog.rs?raw";
import settingsViewSource from "../views/Settings.svelte?raw";
import { settingsSections, type SettingsSectionId } from "./settings-pages";

const views = import.meta.glob("../views/settings/*.svelte", { query: "?raw", import: "default", eager: true }) as Record<string, string>;

function viewSource(file: string): string {
  const key = `../views/settings/${file}`;
  const content = views[key];
  if (!content) throw new Error(`Missing Settings view: ${key}`);
  return content;
}

/** Parses `pub const ENTRIES: &[Entry] = &[ ... ];` from `core/src/settings_catalog.rs`. */
function parseCatalogEntries(): { id: string; section: string }[] {
  const start = catalogSource.indexOf("pub const ENTRIES: &[Entry] = &[");
  if (start < 0) throw new Error("ENTRIES block not found in settings_catalog.rs");
  const end = catalogSource.indexOf("];", start);
  const block = catalogSource.slice(start, end);
  const entries: { id: string; section: string }[] = [];
  const pattern = /Entry\s*\{[\s\S]*?id:\s*"([^"]+)"[\s\S]*?section:\s*"([^"]+)"[\s\S]*?\}/g;
  for (const match of block.matchAll(pattern)) {
    entries.push({ id: match[1], section: match[2] });
  }
  return entries;
}

/** Parses `pub const SECTIONS: &[&str] = &[ ... ];` from `core/src/settings_catalog.rs`. */
function parseCatalogSections(): string[] {
  const start = catalogSource.indexOf("pub const SECTIONS: &[&str] = &[");
  if (start < 0) throw new Error("SECTIONS block not found in settings_catalog.rs");
  const end = catalogSource.indexOf("];", start);
  const block = catalogSource.slice(start, end);
  return [...block.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
}

/**
 * Every BR-20 catalog entry and the exact Settings UI view + save binding that renders the same key (UI-12).
 * Adding a new key to `core/src/settings_catalog.rs` requires adding its UI binding here so the chat can never
 * change a setting that does not exist in the Settings UI under the same section.
 */
const UI_BINDINGS: Record<string, { section: SettingsSectionId; view: string; binding: string }> = {
  app_language: { section: "general", view: "General.svelte", binding: "saveSettings({ appLanguage:" },
  answer_language: { section: "general", view: "General.svelte", binding: "saveSettings({ language:" },
  nook_style: { section: "appearance", view: "Appearance.svelte", binding: "saveSettings({ nookLook:" },
  theme: { section: "appearance", view: "Appearance.svelte", binding: "saveSettings({ theme:" },
  bar_placement: { section: "notch", view: "Notch.svelte", binding: "saveSettings({ placement:" },
  show_bar: { section: "notch", view: "Notch.svelte", binding: "saveSettings({ showBar:" },
  bar_on_all_screens: { section: "notch", view: "Notch.svelte", binding: "saveSettings({ barOnAllScreens:" },
  hide_when_idle: { section: "notch", view: "Notch.svelte", binding: "saveSettings({ hideWhenIdle:" },
  open_on_hover: { section: "notch", view: "Notch.svelte", binding: "saveSettings({ openOnHover:" },
  open_window_at_launch: { section: "notch", view: "Notch.svelte", binding: "saveSettings({ openWindowAtLaunch:" },
  energy_mode: { section: "maintenance", view: "Energy.svelte", binding: "saveSettings({ energyMode:" },
  web_search: { section: "assistant", view: "Assistant.svelte", binding: "saveSettings({ webSearch:" },
  think_along: { section: "assistant", view: "Assistant.svelte", binding: "saveSettings({ autoWatch:" },
  track_screens: { section: "assistant", view: "Assistant.svelte", binding: "saveSettings({ liveScreen:" },
  screens_with_every_question: { section: "assistant", view: "Assistant.svelte", binding: "saveSettings({ screenWithEveryQuestion:" },
  speak_answers: { section: "sound", view: "Voice.svelte", binding: "saveSettings({ speakAnswers:" },
  wake_word: { section: "sound", view: "Voice.svelte", binding: "saveSettings({ wakeWord:" },
  dictation: { section: "dictation", view: "Voice.svelte", binding: "saveFlow({ enabled:" },
  agent_sounds: { section: "sound", view: "Voice.svelte", binding: "saveSettings({ sounds:" },
  notices_agents: { section: "notifications", view: "Voice.svelte", binding: '{ id: "agents"' },
  notices_chats: { section: "notifications", view: "Voice.svelte", binding: '{ id: "chats"' },
  notices_nook: { section: "notifications", view: "Voice.svelte", binding: '{ id: "nook"' },
  notices_suggestions: { section: "notifications", view: "Voice.svelte", binding: '{ id: "suggestions"' },
  use_memory: { section: "memory", view: "Memory.svelte", binding: "saveSettings({ useMemory:" },
  learn_from_chats: { section: "memory", view: "Memory.svelte", binding: "saveSettings({ learnFromChats:" },
  online_lyrics: { section: "connections", view: "Accounts.svelte", binding: "onlineLyrics:" },
};

describe("Settings catalog UI parity (UI-12)", () => {
  it("exposes every Settings subject from settings-pages.ts in open_settings", () => {
    expect(parseCatalogSections()).toEqual([...settingsSections]);
  });

  it("maps every BR-20 catalog entry to a real Settings UI row in the same section", () => {
    const entries = parseCatalogEntries();
    expect(entries.length).toBeGreaterThanOrEqual(26);
    expect(entries.map((e) => e.id).sort()).toEqual(Object.keys(UI_BINDINGS).sort());

    for (const entry of entries) {
      const ui = UI_BINDINGS[entry.id];
      expect(ui, `missing UI binding for ${entry.id}`).toBeDefined();
      expect(entry.section, `${entry.id} section`).toBe(ui.section);
      expect(settingsSections).toContain(entry.section);
      expect(viewSource(ui.view), `${entry.id} in ${ui.view}`).toContain(ui.binding);
    }

    // Energy.svelte is embedded inside Maintenance.svelte, which renders the `maintenance` section.
    expect(viewSource("Maintenance.svelte")).toContain("<Energy");
    expect(settingsViewSource).toContain("maintenance: { component: Maintenance }");
  });
});
