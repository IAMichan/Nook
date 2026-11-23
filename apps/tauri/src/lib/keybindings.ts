// The main window's keys as rules (the Mac's `Keybindings`, docs/KEYBINDINGS.md): a rule says which key runs which
// command, and optionally when. Nook ships the defaults below; your own rules come from `keybindings.json` in Nook's
// data folder (Settings › Shortcuts writes it when you change a key). The defaults come first, then yours, and the
// LAST rule whose key and `when` both match wins; a rule whose command starts with "-" takes that command's key away.
// `mod` is Ctrl (⌘ on a Mac keyboard). Pure, so every rule is tested.

export interface KeybindingRule { key: string; command: string; when?: string }

export interface Chord { mod: boolean; ctrl: boolean; alt: boolean; shift: boolean; key: string }

const ALIASES: Record<string, string> = {
  arrowup: "up", arrowdown: "down", arrowleft: "left", arrowright: "right", return: "enter", esc: "escape", del: "delete", " ": "space",
};
const NAMED = new Set(["up", "down", "left", "right", "enter", "escape", "tab", "space", "backspace", "delete", "home", "end", "pageup", "pagedown"]);

function normalizeKey(raw: string): string | null {
  const k = raw.toLowerCase();
  const name = ALIASES[k] ?? k;
  if (NAMED.has(name) || [...name].length === 1) return name;
  if (/^f([1-9]|1[0-9]|20)$/.test(name)) return name;
  return null;
}

/// `mod+shift+k`, `mod+enter`, `alt+up`, `f6`; null for an unknown modifier or key name.
export function parseChord(text: string): Chord | null {
  const s = text.trim().toLowerCase();
  if (!s) return null;
  let key: string;
  let rest: string[];
  if (s === "+") return { mod: false, ctrl: false, alt: false, shift: false, key: "+" };
  if (s.endsWith("++")) { key = "+"; rest = s.slice(0, -2).split("+").filter(Boolean); }
  else {
    const tokens = s.split("+");
    const last = tokens.pop();
    if (!last) return null;
    key = last;
    rest = tokens;
  }
  const normalized = normalizeKey(key);
  if (!normalized) return null;
  const chord: Chord = { mod: false, ctrl: false, alt: false, shift: false, key: normalized };
  for (const token of rest) {
    if (token === "mod" || token === "cmd" || token === "meta" || token === "command") chord.mod = true;
    else if (token === "ctrl" || token === "control") chord.ctrl = true;
    else if (token === "alt" || token === "option") chord.alt = true;
    else if (token === "shift") chord.shift = true;
    else return null;
  }
  return chord;
}

type KeyEvent = Pick<KeyboardEvent, "key" | "code" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey">;

/// The chord a key event is, as a rule would write it. Ctrl and ⌘ both count as `mod`; Shift is left out of a
/// character it already shaped ("?" is Shift+/), so `mod+/` and `?` read the way they are written.
export function eventChord(e: KeyEvent): Chord | null {
  let key = e.key;
  // Ctrl with a digit or bracket can come with another character on some layouts: the physical key decides.
  if (/^Digit[0-9]$/.test(e.code ?? "")) key = e.code.slice(5);
  else if (e.code === "BracketLeft" && (e.ctrlKey || e.metaKey)) key = "[";
  else if (e.code === "BracketRight" && (e.ctrlKey || e.metaKey)) key = "]";
  const normalized = normalizeKey(key);
  if (!normalized || ["control", "shift", "alt", "meta"].includes(normalized)) return null;
  const printable = [...normalized].length === 1 && !/[a-z0-9]/.test(normalized);
  return { mod: e.ctrlKey || e.metaKey, ctrl: false, alt: e.altKey, shift: e.shiftKey && !printable, key: normalized };
}

export function sameChord(a: Chord, b: Chord): boolean {
  return a.mod === b.mod && a.ctrl === b.ctrl && a.alt === b.alt && a.shift === b.shift && a.key === b.key;
}

/// A chord as a rule writes it: `mod+shift+k`.
export function chordText(c: Chord): string {
  return [c.mod && "mod", c.ctrl && "ctrl", c.alt && "alt", c.shift && "shift", c.key].filter(Boolean).join("+");
}

/// A chord as the keyboard shows it: "Ctrl+Shift+K" (⌘⇧K on a Mac keyboard).
export function chordLabel(c: Chord, mac = false): string {
  const names: Record<string, string> = { up: "↑", down: "↓", left: "←", right: "→", enter: mac ? "↩" : "Enter", escape: "Esc", space: "Space", tab: "Tab", backspace: "Backspace", delete: "Del" };
  const key = names[c.key] ?? (c.key.length === 1 ? c.key.toUpperCase() : c.key.toUpperCase());
  if (mac) return `${c.ctrl ? "⌃" : ""}${c.alt ? "⌥" : ""}${c.shift ? "⇧" : ""}${c.mod ? "⌘" : ""}${key}`;
  return [c.mod && "Ctrl", c.ctrl && !c.mod && "Ctrl", c.alt && "Alt", c.shift && "Shift", key].filter(Boolean).join("+");
}

// MARK: When

export type Context = Record<string, boolean>;

/// Evaluates `!a && (b || c)` against the context; an unknown name is false; null for text that does not parse.
export function evaluateWhen(text: string, context: Context): boolean | null {
  const tokens = text.match(/\(|\)|!|&&|\|\||[A-Za-z_][\w.]*|\S/g) ?? [];
  let pos = 0;
  const or = (): boolean | null => {
    let left = and();
    while (left !== null && tokens[pos] === "||") { pos++; const right = and(); left = right === null ? null : left || right; }
    return left;
  };
  const and = (): boolean | null => {
    let left = not();
    while (left !== null && tokens[pos] === "&&") { pos++; const right = not(); left = right === null ? null : left && right; }
    return left;
  };
  const not = (): boolean | null => {
    const t = tokens[pos];
    if (t === undefined) return null;
    if (t === "!") { pos++; const v = not(); return v === null ? null : !v; }
    if (t === "(") { pos++; const v = or(); if (tokens[pos] !== ")") return null; pos++; return v; }
    if (!/^[A-Za-z_]/.test(t)) return null;
    pos++;
    return !!context[t];
  };
  const value = or();
  return value !== null && pos === tokens.length ? value : null;
}

export function ruleIsValid(rule: KeybindingRule): boolean {
  if (!rule || typeof rule.key !== "string" || typeof rule.command !== "string" || !rule.command.trim()) return false;
  if (!parseChord(rule.key)) return false;
  return !rule.when?.trim() || evaluateWhen(rule.when, {}) !== null;
}

// MARK: Defaults

/// The commands of the main window, in the cheat sheet's order. The shell runs the navigation ones itself; the rest go
/// to the view on screen as a `nook-command` event (`lib/commands.ts`).
export const DEFAULT_RULES: KeybindingRule[] = [
  { key: "mod+enter", command: "composer.send", when: "composerFocus && !turnRunning" },
  { key: "mod+enter", command: "composer.sendAlternate", when: "composerFocus && turnRunning" },
  { key: "shift+enter", command: "composer.newline", when: "composerFocus" },
  { key: "mod+s", command: "composer.stash", when: "composerFocus" },
  { key: "mod+shift+d", command: "composer.dictate", when: "composerFocus && !terminalFocus" },
  { key: "alt+up", command: "composer.historyPrevious", when: "composerFocus" },
  { key: "alt+down", command: "composer.historyNext", when: "composerFocus" },
  { key: "shift+tab", command: "composer.access", when: "composerFocus" },
  { key: "mod+z", command: "composer.undo", when: "composerFocus" },
  { key: "mod+shift+z", command: "composer.redo", when: "composerFocus" },
  { key: "mod+shift+v", command: "composer.pasteAsText", when: "composerFocus" },
  { key: "mod+shift+enter", command: "queue.steerFirst", when: "composerFocus && turnRunning" },
  { key: "mod+alt+enter", command: "composer.startInBackground", when: "composerFocus" },
  { key: "mod+k", command: "search.toggle", when: "!terminalFocus" },
  { key: "mod+shift+k", command: "commandPalette.toggle", when: "!terminalFocus" },
  { key: "mod+f", command: "chat.find", when: "!terminalFocus" },
  { key: "mod+/", command: "shortcuts.cheatSheet", when: "!terminalFocus" },
  { key: "?", command: "shortcuts.cheatSheet", when: "!editableFocus && !terminalFocus" },
  { key: "mod+,", command: "settings.open" },
  { key: "f6", command: "focus.next" },
  { key: "shift+f6", command: "focus.previous" },
  { key: "mod+n", command: "session.new", when: "!terminalFocus" },
  { key: "mod+.", command: "session.interrupt" },
  { key: "mod+[", command: "session.back", when: "!terminalFocus" },
  { key: "mod+]", command: "session.forward", when: "!terminalFocus" },
  { key: "mod+shift+[", command: "session.previous" },
  { key: "mod+shift+]", command: "session.next" },
  { key: "mod+shift+p", command: "session.pin", when: "!terminalFocus" },
  { key: "f2", command: "session.rename", when: "!editableFocus && !terminalFocus" },
  { key: "mod+shift+s", command: "session.settle", when: "!terminalFocus" },
  { key: "mod+z", command: "session.undo", when: "!terminalFocus && !editableFocus && !composerFocus" },
  { key: "mod+shift+c", command: "session.copyReference", when: "!terminalFocus && !editableFocus" },
  { key: "mod+o", command: "session.openInEditor", when: "!terminalFocus" },
  { key: "mod+b", command: "sidebar.toggle", when: "!terminalFocus && !editableFocus" },
  { key: "mod+j", command: "terminal.toggle" },
  { key: "mod+alt+b", command: "sidePanel.toggle" },
  { key: "mod+shift+b", command: "sessionPanel.toggle", when: "!terminalFocus" },
  { key: "mod+d", command: "diff.toggle", when: "!terminalFocus" },
  { key: "mod+shift+t", command: "panel.reopenClosed", when: "!terminalFocus" },
  { key: "mod+w", command: "tab.close", when: "terminalFocus || panelFocus" },
  { key: "mod+d", command: "terminal.splitRight", when: "terminalFocus" },
  { key: "mod+shift+d", command: "terminal.splitDown", when: "terminalFocus" },
  { key: "mod+shift+m", command: "modelPicker.toggle", when: "!terminalFocus" },
  { key: "mod+shift+e", command: "effortPicker.toggle", when: "!terminalFocus" },
  { key: "mod+shift+a", command: "permissionPicker.toggle", when: "!terminalFocus" },
  { key: "mod+l", command: "selection.ask", when: "!terminalFocus && !editableFocus" },
  { key: "mod+shift+l", command: "selection.quote", when: "!terminalFocus && !editableFocus" },
  ...Array.from({ length: 9 }, (_, i) => ({ key: `mod+${i + 1}`, command: `tab.jump${i + 1}` })),
];

/// The defaults and the user's rules, in the order they are weighed (the last match wins). Invalid user rules are
/// left out; `-command` rules stay, to take that command's earlier keys away.
export function effectiveRules(user: KeybindingRule[]): KeybindingRule[] {
  return [...DEFAULT_RULES, ...user.filter(ruleIsValid)];
}

/// The command a key event runs in this context, or null.
export function resolve(e: KeyEvent, context: Context, rules: KeybindingRule[]): string | null {
  const chord = eventChord(e);
  if (!chord) return null;
  for (let i = rules.length - 1; i >= 0; i--) {
    const rule = rules[i];
    const ruleChord = parseChord(rule.key);
    if (!ruleChord || !sameChord(ruleChord, chord)) continue;
    if (rule.when?.trim() && evaluateWhen(rule.when, context) !== true) continue;
    if (rule.command.startsWith("-")) return null;
    // A key whose command was taken away by a later "-command" rule is free again.
    if (rules.slice(i + 1).some((r) => r.command === `-${rule.command}` && sameChordText(r.key, rule.key))) continue;
    return rule.command;
  }
  return null;
}

function sameChordText(a: string, b: string): boolean {
  const x = parseChord(a);
  const y = parseChord(b);
  return !!x && !!y && sameChord(x, y);
}

/// The keys a command answers to now, for the cheat sheet and Settings.
export function chordsFor(command: string, rules: KeybindingRule[]): Chord[] {
  const out: Chord[] = [];
  rules.forEach((rule, i) => {
    if (rule.command !== command) return;
    const chord = parseChord(rule.key);
    if (!chord) return;
    const removed = rules.slice(i + 1).some((r) => r.command === `-${command}` && sameChordText(r.key, rule.key));
    // A later rule that gives the same chord to another command takes it.
    const taken = rules.slice(i + 1).some((r) => r.command !== command && !r.command.startsWith("-") && !r.when && sameChordText(r.key, rule.key));
    if (!removed && !taken && !out.some((c) => sameChord(c, chord))) out.push(chord);
  });
  return out;
}

/// The user's rules after giving `command` the chord `key` instead of its defaults (null puts the defaults back).
export function rebind(user: KeybindingRule[], command: string, key: string | null): KeybindingRule[] {
  const kept = user.filter((r) => r.command !== command && r.command !== `-${command}`);
  if (key === null) return kept;
  const removals = DEFAULT_RULES.filter((r) => r.command === command).map((r) => ({ key: r.key, command: `-${command}`, when: r.when }));
  const when = DEFAULT_RULES.find((r) => r.command === command)?.when;
  return [...kept, ...removals, { key, command, ...(when ? { when } : {}) }];
}

/// Two commands that answer to the same chord in the same context, for Settings to warn about.
export function conflicts(rules: KeybindingRule[]): { key: string; commands: string[] }[] {
  const byKey = new Map<string, Set<string>>();
  for (const r of rules) {
    if (r.command.startsWith("-")) continue;
    const c = parseChord(r.key);
    if (!c || chordsFor(r.command, rules).every((x) => !sameChord(x, c))) continue;
    const id = `${chordText(c)}|${r.when ?? ""}`;
    byKey.set(id, (byKey.get(id) ?? new Set()).add(r.command));
  }
  return [...byKey].filter(([, s]) => s.size > 1).map(([id, s]) => ({ key: id.split("|")[0], commands: [...s] }));
}
