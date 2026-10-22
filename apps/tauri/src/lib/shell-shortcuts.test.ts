import { describe, expect, it } from "vitest";
import { shellShortcut } from "./shell-shortcuts";

const key = { key: "k", ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, repeat: false, isComposing: false, defaultPrevented: false };
const context = { paletteOpen: false, modalOpen: false, editing: false, chat: true };

describe("shell shortcuts", () => {
  it("opens and closes the switcher with either platform modifier", () => {
    expect(shellShortcut(key, context)).toBe("palette");
    expect(shellShortcut({ ...key, ctrlKey: false, metaKey: true }, { ...context, paletteOpen: true, modalOpen: true })).toBe("palette");
    expect(shellShortcut({ ...key, ctrlKey: false }, context)).toBeNull();
  });

  it("leaves repeated, composing, modified and already handled events alone", () => {
    for (const flag of ["repeat", "isComposing", "altKey", "shiftKey", "defaultPrevented"]) {
      expect(shellShortcut({ ...key, [flag]: true }, context)).toBeNull();
    }
  });

  it("keeps sidebar shortcuts out of editors, terminals and other routes", () => {
    const b = { ...key, key: "b" };
    expect(shellShortcut(b, context)).toBe("sidebar");
    expect(shellShortcut(b, { ...context, editing: true })).toBeNull();
    expect(shellShortcut(b, { ...context, chat: false })).toBeNull();
    expect(shellShortcut(b, { ...context, paletteOpen: true })).toBeNull();
  });

  it("does not navigate or stop work behind a modal", () => {
    for (const value of ["k", "b", "n", ",", "."]) {
      expect(shellShortcut({ ...key, key: value }, { ...context, modalOpen: true })).toBeNull();
    }
    for (const value of ["b", "n", ",", "."]) {
      expect(shellShortcut({ ...key, key: value }, { ...context, paletteOpen: true, modalOpen: true })).toBeNull();
    }
  });

  it("preserves new conversation, settings and stop shortcuts", () => {
    expect(shellShortcut({ ...key, key: "n" }, context)).toBe("new");
    expect(shellShortcut({ ...key, key: "," }, context)).toBe("settings");
    expect(shellShortcut({ ...key, key: "." }, context)).toBe("stop");
  });
});
