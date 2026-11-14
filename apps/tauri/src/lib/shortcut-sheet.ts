// The cheat sheet of the keys inside Nook's main window (Settings › Shortcuts, `ShortcutCheatSheetView` on the Mac).
// Every entry with a `shell` id is checked against `shellShortcut` in the tests, so the sheet cannot drift from the keys.

export type SheetGroup = "navigation" | "session" | "composer" | "other";

export interface SheetEntry {
  /// The keys as shown, with "Mod" for Ctrl (⌘ on a Mac keyboard).
  keys: string[];
  /// The English name (the page shows it translated).
  name: string;
  group: SheetGroup;
  /// The `shellShortcut` it stands for, when it is one; the keys are then pressed with Ctrl.
  shell?: string;
}

export const SHEET: SheetEntry[] = [
  { keys: ["Mod", "K"], name: "Command palette", group: "navigation", shell: "palette" },
  { keys: ["Mod", "F"], name: "Search conversations, or settings in Settings", group: "navigation", shell: "search" },
  { keys: ["Mod", "1…9"], name: "Go to a page in the sidebar", group: "navigation", shell: "go-1" },
  { keys: ["Mod", ","], name: "Open Settings", group: "navigation", shell: "settings" },
  { keys: ["/"], name: "Search settings", group: "navigation" },
  { keys: ["Mod", "N"], name: "New Nook", group: "session", shell: "new" },
  { keys: ["Mod", "."], name: "Stop the answer", group: "session", shell: "stop" },
  { keys: ["Mod", "B"], name: "Show or hide the conversations", group: "session", shell: "sidebar" },
  { keys: ["Enter"], name: "Send", group: "composer" },
  { keys: ["Shift", "Enter"], name: "New line", group: "composer" },
  { keys: ["↑", "↓"], name: "Earlier questions", group: "composer" },
  { keys: ["Esc"], name: "Stop the answer while it is being written", group: "composer" },
  { keys: ["Mod", "Enter"], name: "Run the plan that waits for you", group: "composer" },
  { keys: ["Esc"], name: "Close a dialog or the palette", group: "other" },
];

/// The key's label on this keyboard: Ctrl, or ⌘ on a Mac keyboard.
export function keyLabel(key: string, mac: boolean): string {
  return key === "Mod" ? (mac ? "⌘" : "Ctrl") : key;
}
