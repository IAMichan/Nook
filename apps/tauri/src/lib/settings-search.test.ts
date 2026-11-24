import { describe, expect, it } from "vitest";
import { SETTINGS_INDEX, settingHits } from "./settings-search.svelte";
import { settingsSections } from "./settings-pages";

const pages = Object.values(import.meta.glob("../views/settings/*.svelte", { query: "?raw", import: "default", eager: true }) as Record<string, string>).join("\n");

describe("Settings search", () => {
  it("indexes every setting by the name its page shows", () => {
    for (const [nl, en, section] of SETTINGS_INDEX) {
      expect(settingsSections).toContain(section);
      expect(pages, `${en} (${section})`).toContain(`tr("${nl}", "${en}")`);
    }
    expect(SETTINGS_INDEX.length).toBeGreaterThan(150);
  });

  it("finds a setting by any word of its name, on the subject that shows it", () => {
    const hits = settingHits("branch", () => true);
    expect(hits).toContainEqual({ title: "Branch prefix", section: "worktrees" });
    expect(settingHits("branch", (id) => id !== "worktrees").some((h) => h.section === "worktrees")).toBe(false);
    expect(settingHits("  ", () => true)).toEqual([]);
  });
});
