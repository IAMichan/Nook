import { describe, expect, it } from "vitest";
import { DEFAULT_RULES, chordLabel, chordsFor, conflicts, effectiveRules, evaluateWhen, eventChord, parseChord, rebind, resolve } from "./keybindings";
import { shellShortcut } from "./shell-shortcuts";
import { onCommand, runCommand } from "./commands";
import { commandName } from "./command-names";

const key = (k: string, more: Partial<KeyboardEvent> = {}) => ({ key: k, code: "", ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, ...more });

describe("chords", () => {
  it("parses the Mac's notation", () => {
    expect(parseChord("mod+shift+k")).toEqual({ mod: true, ctrl: false, alt: false, shift: true, key: "k" });
    expect(parseChord("alt+ArrowUp")?.key).toBe("up");
    expect(parseChord("f6")?.key).toBe("f6");
    expect(parseChord("hyper+k")).toBeNull();
    expect(parseChord("mod+")).toBeNull();
  });

  it("reads a key event, with Shift left out of a character it shaped", () => {
    expect(eventChord(key("?", { shiftKey: true }))).toEqual({ mod: false, ctrl: false, alt: false, shift: false, key: "?" });
    expect(eventChord(key("K", { ctrlKey: true, shiftKey: true }))?.shift).toBe(true);
    expect(eventChord(key("&", { ctrlKey: true, code: "Digit1" }))?.key).toBe("1");
    expect(eventChord(key("Control", { ctrlKey: true }))).toBeNull();
  });

  it("labels keys for Windows and a Mac keyboard", () => {
    expect(chordLabel(parseChord("mod+shift+k")!)).toBe("Ctrl+Shift+K");
    expect(chordLabel(parseChord("mod+shift+k")!, true)).toBe("⇧⌘K");
  });
});

describe("when", () => {
  it("evaluates and rejects nonsense", () => {
    expect(evaluateWhen("!a && (b || c)", { b: true })).toBe(true);
    expect(evaluateWhen("a &&", {})).toBeNull();
    expect(evaluateWhen("a b", {})).toBeNull();
  });
});

describe("rules", () => {
  it("lets the last matching rule win and takes keys away with -command", () => {
    const user = [{ key: "mod+k", command: "session.pin" }];
    expect(resolve(key("k", { ctrlKey: true }), {}, effectiveRules(user))).toBe("session.pin");
    expect(resolve(key("k", { ctrlKey: true }), {}, effectiveRules([{ key: "mod+k", command: "-search.toggle" }]))).toBeNull();
    expect(resolve(key("k", { ctrlKey: true }), { terminalFocus: true }, DEFAULT_RULES)).toBeNull();
  });

  it("rebinds a command and puts the default back", () => {
    const user = rebind([], "session.pin", "mod+alt+p");
    const rules = effectiveRules(user);
    expect(chordsFor("session.pin", rules).map((c) => chordLabel(c))).toEqual(["Ctrl+Alt+P"]);
    expect(resolve(key("P", { ctrlKey: true, shiftKey: true }), {}, rules)).toBeNull();
    expect(rebind(user, "session.pin", null)).toEqual([]);
  });

  it("finds two commands on one key", () => {
    const rules = effectiveRules([{ key: "mod+j", command: "session.pin" }]);
    expect(chordsFor("terminal.toggle", rules)).toEqual([]);
    expect(conflicts(DEFAULT_RULES)).toEqual([]);
  });

  it("names every default command", () => {
    for (const r of DEFAULT_RULES) expect(commandName(r.command)).not.toBe(r.command);
  });

  it("sends a command the shell does not run to the view on screen", () => {
    const context = { paletteOpen: false, modalOpen: false, editing: false, chat: true };
    expect(shellShortcut({ ...key("P", { ctrlKey: true, shiftKey: true }), repeat: false, isComposing: false, defaultPrevented: false }, context)).toBe("cmd:session.pin");
    let ran = 0;
    const off = onCommand("session.pin", () => { ran++; });
    const off2 = onCommand("session.pin", () => false);
    expect(runCommand("session.pin")).toBe(true);
    expect(ran).toBe(1);
    off(); off2();
    expect(runCommand("session.pin")).toBe(false);
  });
});
