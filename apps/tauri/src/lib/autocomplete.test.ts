import { describe, expect, it } from "vitest";
import { appRule, nextChunk, normalizeApp, offByDefault, withAppRule, type AutocompleteSettings } from "./autocomplete";

const base = { apps: {} } as unknown as AutocompleteSettings;

describe("autocomplete helpers", () => {
  it("takes the next word like the Mac", () => {
    expect(nextChunk(" there, my friend.")).toBe(" there");
    expect(nextChunk(", my friend.")).toBe(",");
    expect(nextChunk(" friend.", true)).toBe(" friend.");
    expect(nextChunk(" one two", false, true)).toBe(" one ");
    expect(nextChunk(" nook.app is")).toBe(" nook.app");
    expect(nextChunk("   ")).toBe("");
  });

  it("matches apps by exe name", () => {
    expect(normalizeApp("Code.EXE")).toBe("code");
    const patterns = ["WindowsTerminal.exe", "KeePass*.exe"];
    expect(offByDefault("WindowsTerminal", patterns)).toBe(true);
    expect(offByDefault("KeePassXC.exe", patterns)).toBe(true);
    expect(offByDefault("notepad.exe", patterns)).toBe(false);
  });

  it("keeps only rules that differ from the default", () => {
    let s = withAppRule(base, "Slack.exe", { enabled: "off", midLine: "inherit", leaveTab: false, instructions: "" });
    expect(appRule(s, "slack").enabled).toBe("off");
    s = withAppRule(s, "SLACK", { enabled: "inherit", midLine: "inherit", leaveTab: false, instructions: " " });
    expect(Object.keys(s.apps)).toEqual([]);
  });
});
