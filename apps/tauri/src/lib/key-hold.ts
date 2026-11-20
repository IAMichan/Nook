// The pure part of holding Ctrl for key hints (`key-hold.svelte.ts`), so it is tested without a window.

type Keys = Pick<KeyboardEvent, "key" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey">;

/// True for the key event of Ctrl going down with no other modifier (⌘ on a Mac keyboard, as the Mac's ⌘).
export function holdsCtrlAlone(e: Keys): boolean {
  const ctrl = e.key === "Control" && e.ctrlKey && !e.metaKey;
  const meta = e.key === "Meta" && e.metaKey && !e.ctrlKey;
  return (ctrl || meta) && !e.altKey && !e.shiftKey;
}

/// The hint beside the n-th (0-based) item of a list or tab bar: Ctrl+1 … Ctrl+9, nothing past the ninth.
export function numberHint(index: number, mac = false): string | null {
  return index >= 0 && index < 9 ? `${mac ? "⌘" : "Ctrl+"}${index + 1}` : null;
}
