type Key = Pick<KeyboardEvent, "key" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey" | "repeat" | "isComposing" | "defaultPrevented">;
type Context = { paletteOpen: boolean; modalOpen: boolean; editing: boolean; chat: boolean };
type Shortcut = "palette" | "sidebar" | "new" | "settings" | "stop";

export function shellShortcut(e: Key, context: Context): Shortcut | null {
  if (e.defaultPrevented || e.repeat || e.isComposing || e.altKey || e.shiftKey || !(e.ctrlKey || e.metaKey)) return null;
  if (context.modalOpen && !context.paletteOpen) return null;
  const key = e.key.toLowerCase();
  if (key === "k") return "palette";
  if (context.paletteOpen) return null;
  if (key === "b" && context.chat && !context.editing) return "sidebar";
  if (key === "n") return "new";
  if (key === ",") return "settings";
  if (key === ".") return "stop";
  return null;
}
