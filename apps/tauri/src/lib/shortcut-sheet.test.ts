import { describe, expect, it } from "vitest";
import { SHEET, keyLabel } from "./shortcut-sheet";
import { shellShortcut } from "./shell-shortcuts";

const press = (key: string) => ({ key, ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, repeat: false, isComposing: false, defaultPrevented: false });

describe("shortcut cheat sheet", () => {
  it("lists the main window's keys as shellShortcut knows them", () => {
    const context = { paletteOpen: false, modalOpen: false, editing: false, chat: true };
    for (const entry of SHEET.filter((e) => e.shell)) {
      const key = entry.keys[1] === "1…9" ? "1" : entry.keys[1].toLowerCase();
      expect(entry.keys[0]).toBe("Mod");
      expect(shellShortcut(press(key), context)).toBe(entry.shell);
    }
  });

  it("covers every shell shortcut", () => {
    const listed = new Set(SHEET.map((e) => e.shell));
    for (const id of ["palette", "sidebar", "new", "settings", "stop", "search", "go-1"]) expect(listed.has(id)).toBe(true);
  });

  it("names Ctrl, or ⌘ on a Mac keyboard", () => {
    expect(keyLabel("Mod", false)).toBe("Ctrl");
    expect(keyLabel("Mod", true)).toBe("⌘");
    expect(keyLabel("K", false)).toBe("K");
  });
});
