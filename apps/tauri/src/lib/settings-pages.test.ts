import { describe, expect, it } from "vitest";
import {
  pageTitle, sectionTrail, settingsGroup, settingsGroups, settingsHost, settingsPages, settingsParts, settingsSection, settingsSections,
} from "./settings-pages";

describe("Settings pages", () => {
  it("puts every subject on exactly one page", () => {
    const placed = settingsGroups.flatMap((g) => settingsPages[g].flatMap((p) => p.parts));
    expect([...placed].sort()).toEqual([...settingsSections].sort());
    expect(new Set(placed).size).toBe(placed.length);
    for (const g of settingsGroups) for (const p of settingsPages[g]) expect(p.parts[0]).toBe(p.page);
  });

  it("follows the Mac's groups and pages", () => {
    // `SettingsSection.Group.sections` on the Mac; Projects waits for UI-29, Gamer Mode is Tauri-first.
    expect(settingsGroups).toEqual(["nook", "intelligence", "agents", "connect", "system"]);
    const pages = (g: (typeof settingsGroups)[number]) => settingsPages[g].map((p) => p.page);
    expect(pages("nook")).toEqual(["start", "general", "appearance", "notifications", "shortcuts", "games"]);
    expect(pages("intelligence")).toEqual(["brain", "assistant", "autocomplete"]);
    expect(pages("agents")).toEqual(["agents", "sessions", "automation"]);
    expect(pages("connect")).toEqual(["chats", "connections", "iphone", "privacy"]);
    expect(pages("system")).toEqual(["maintenance"]);
  });

  it("finds a subject's page, its parts and its group", () => {
    expect(settingsHost("memory")).toBe("assistant");
    expect(settingsParts("instructions")).toEqual(["assistant", "memory", "instructions"]);
    expect(settingsHost("dictation")).toBe("autocomplete");
    expect(settingsGroup("archive")).toBe("agents");
    expect(settingsGroup("about")).toBe("system");
    expect(settingsParts("brain")).toEqual(["brain"]);
  });

  it("names pages and trails as the Mac does", () => {
    expect(pageTitle("autocomplete")).toBe("Typing");
    expect(pageTitle("maintenance")).toBe("System");
    expect(sectionTrail("dictation")).toBe("Typing › Dictation");
    expect(sectionTrail("brain")).toBe("Brain");
  });

  it("opens the subject an old page id or another name stands for", () => {
    expect(settingsSection("overview")).toBe("start");
    expect(settingsSection("accounts")).toBe("connections");
    expect(settingsSection("voice")).toBe("sound");
    expect(settingsSection("companion")).toBe("iphone");
    expect(settingsSection("memory")).toBe("memory");
    for (const value of [null, undefined, "", "__proto__", "toString", "missing"]) expect(settingsSection(value)).toBe("start");
  });
});
