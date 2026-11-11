import { describe, expect, it } from "vitest";
import { readableShortcut, recordShortcut } from "./accelerator";

const press = (code: string, mods: Partial<{ ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean }> = {}, key = code) =>
  ({ key, code, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...mods });

describe("recording a shortcut", () => {
  it("records the combination as an accelerator", () => {
    expect(recordShortcut(press("Space", { ctrlKey: true, altKey: true }, " "))).toEqual({ kind: "done", accelerator: "Alt+CommandOrControl+Space" });
    expect(recordShortcut(press("KeyK", { ctrlKey: true, shiftKey: true }, "K"))).toEqual({ kind: "done", accelerator: "CommandOrControl+Shift+K" });
    expect(recordShortcut(press("Digit4", { metaKey: true }, "4"))).toEqual({ kind: "done", accelerator: "Super+4" });
    expect(recordShortcut(press("F9"))).toEqual({ kind: "done", accelerator: "F9" });
  });

  it("waits while only modifiers are down", () => {
    expect(recordShortcut(press("ControlLeft", { ctrlKey: true }, "Control"))).toEqual({ kind: "waiting" });
  });

  it("cancels on Escape, clears on Backspace, and refuses a bare letter", () => {
    expect(recordShortcut(press("Escape", {}, "Escape"))).toEqual({ kind: "cancel" });
    expect(recordShortcut(press("Backspace", {}, "Backspace"))).toEqual({ kind: "clear" });
    expect(recordShortcut(press("KeyA", {}, "a")).kind).toBe("invalid");
    expect(recordShortcut(press("KeyA", { shiftKey: true }, "A")).kind).toBe("invalid");
    expect(recordShortcut(press("IntlRo", { ctrlKey: true }, "\\")).kind).toBe("invalid");
  });
});

describe("readable shortcuts", () => {
  it("shows modifiers the way Windows writes them", () => {
    expect(readableShortcut("Alt+CommandOrControl+Space")).toBe("Ctrl + Alt + Space");
    expect(readableShortcut("Super+Shift+K")).toBe("Shift + Win + K");
    expect(readableShortcut("")).toBe("—");
  });
});
