// The main window's key handling: a key event becomes a command through the rules in `keybindings.ts` (the defaults
// and your own `keybindings.json`). The shell runs its own commands (the names below); every other command goes to the
// view on screen as `cmd:<command>` (`lib/commands.ts`).
import { keyFlags } from "./key-context";
import { DEFAULT_RULES, resolve, type KeybindingRule } from "./keybindings";

type Key = Pick<KeyboardEvent, "key" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey" | "repeat" | "isComposing" | "defaultPrevented"> & { code?: string };
type Context = {
  paletteOpen: boolean; modalOpen: boolean; editing: boolean;
  /// The tab on screen has a sidebar list Ctrl+B puts away (Nook, Agents).
  chat: boolean;
  terminal?: boolean; composer?: boolean; panel?: boolean;
};
export type Shortcut =
  | "palette" | "sidebar" | "new" | "settings" | "stop" | "search" | "back" | "forward" | "cheatsheet"
  | "focus-next" | "focus-previous" | `go-${number}` | `cmd:${string}`;

/// The commands the shell runs itself, by the name its handler uses.
const SHELL: Record<string, Shortcut> = {
  "search.toggle": "palette",
  "commandPalette.toggle": "palette",
  "chat.find": "search",
  "shortcuts.cheatSheet": "cheatsheet",
  "settings.open": "settings",
  "focus.next": "focus-next",
  "focus.previous": "focus-previous",
  "session.new": "new",
  "session.interrupt": "stop",
  "session.back": "back",
  "session.forward": "forward",
  "sidebar.toggle": "sidebar",
};

export function shellShortcut(e: Key, context: Context, rules: KeybindingRule[] = DEFAULT_RULES): Shortcut | null {
  if (e.defaultPrevented || e.isComposing || e.repeat) return null;
  // Behind a dialog only the palette's own key works, and only to close it.
  if (context.modalOpen && !context.paletteOpen) return null;
  const command = resolve({ ...e, code: e.code ?? "" }, {
    editableFocus: context.editing,
    terminalFocus: !!context.terminal,
    composerFocus: !!context.composer,
    panelFocus: !!context.panel,
    paletteOpen: context.paletteOpen,
    ...keyFlags,
    sidebarTab: context.chat,
  }, rules);
  if (!command) return null;
  if (context.paletteOpen && command !== "search.toggle") return null;
  if (command === "sidebar.toggle" && (!context.chat || context.editing)) return null;
  const jump = /^tab\.jump([1-9])$/.exec(command);
  if (jump) return `go-${Number(jump[1])}`;
  return SHELL[command] ?? `cmd:${command}`;
}

/// The window's areas in F6 order (`focus.next`): the sidebar, the page, the composer when there is one, and the tab
/// beside the main one in split view.
export const FOCUS_AREAS = [".rail", ".content", ".content textarea, .content [contenteditable='true']", ".beside"] as const;

/// The index of the area after (or before) `current` in a list of `count` areas, wrapping around; -1 starts at the top.
export function nextArea(current: number, count: number, backwards: boolean): number {
  if (count <= 0) return -1;
  if (current < 0) return backwards ? count - 1 : 0;
  return (current + (backwards ? count - 1 : 1)) % count;
}
