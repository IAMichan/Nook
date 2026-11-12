// Turns a key press into a global shortcut ("Alt+CommandOrControl+Space") and back into something readable
// ("Ctrl+Alt+Space"). Settings records a shortcut by pressing it, instead of asking you to type the accelerator syntax.

type Key = Pick<KeyboardEvent, "key" | "code" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey">;

const NAMED: Record<string, string> = {
  Space: "Space", Enter: "Enter", Tab: "Tab", Backspace: "Backspace", Delete: "Delete", Insert: "Insert",
  Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown",
  ArrowUp: "Up", ArrowDown: "Down", ArrowLeft: "Left", ArrowRight: "Right",
  Minus: "Minus", Equal: "Equal", Comma: "Comma", Period: "Period", Slash: "Slash", Backslash: "Backslash",
  Semicolon: "Semicolon", Quote: "Quote", Backquote: "Backquote", BracketLeft: "BracketLeft", BracketRight: "BracketRight",
};

const MODIFIER_KEYS = new Set(["Control", "Alt", "Shift", "Meta", "AltGraph", "OS"]);

export type Recorded = { kind: "waiting" } | { kind: "cancel" } | { kind: "clear" } | { kind: "invalid"; reason: string } | { kind: "done"; accelerator: string };

/// What a key press means while a shortcut field is recording.
export function recordShortcut(e: Key): Recorded {
  if (MODIFIER_KEYS.has(e.key)) return { kind: "waiting" };
  const plain = !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey;
  if (plain && e.key === "Escape") return { kind: "cancel" };
  if (plain && (e.key === "Backspace" || e.key === "Delete")) return { kind: "clear" };
  const key = keyName(e.code);
  if (!key) return { kind: "invalid", reason: "Deze toets kan geen sneltoets zijn." };
  const fn = /^F\d{1,2}$/.test(key);
  if (!fn && !e.ctrlKey && !e.metaKey && !e.altKey) return { kind: "invalid", reason: "Houd ook Ctrl, Alt of Windows ingedrukt." };
  const parts: string[] = [];
  if (e.altKey) parts.push("Alt");
  if (e.ctrlKey) parts.push("CommandOrControl");
  if (e.metaKey) parts.push("Super");
  if (e.shiftKey) parts.push("Shift");
  parts.push(key);
  return { kind: "done", accelerator: parts.join("+") };
}

function keyName(code: string): string | null {
  if (/^Key[A-Z]$/.test(code)) return code.slice(3);
  if (/^Digit\d$/.test(code)) return code.slice(5);
  if (/^F\d{1,2}$/.test(code)) return code;
  return NAMED[code] ?? null;
}

/// "Alt+CommandOrControl+Space" → "Ctrl + Alt + Space", in the order Windows shows modifiers.
export function readableShortcut(accelerator: string): string {
  if (!accelerator.trim()) return "—";
  const parts = accelerator.split("+").map((p) => p.trim()).filter(Boolean);
  const order = ["Ctrl", "Alt", "Shift", "Win"];
  const mods: string[] = [];
  const keys: string[] = [];
  for (const part of parts) {
    const lower = part.toLowerCase();
    if (["commandorcontrol", "cmdorctrl", "control", "ctrl", "command", "cmd"].includes(lower)) mods.push("Ctrl");
    else if (["alt", "option"].includes(lower)) mods.push("Alt");
    else if (lower === "shift") mods.push("Shift");
    else if (["super", "meta", "win"].includes(lower)) mods.push("Win");
    else keys.push(part);
  }
  mods.sort((a, b) => order.indexOf(a) - order.indexOf(b));
  return [...new Set(mods), ...keys].join(" + ");
}
