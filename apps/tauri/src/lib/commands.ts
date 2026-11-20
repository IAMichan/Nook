// Commands from the keyboard for the view on screen (the Mac's `.keyCommand`): the shell resolves a key to a command
// (`shell-shortcuts.ts`) and, when it is not one of its own, sends it here. A view that offers the command registers
// a handler with `onCommand` while it is on screen; the newest handler goes first, and one that returns false hands
// the key on to the one before it. A command nothing on screen handles leaves the key to the focused field.

type Handler = () => boolean | void;
const handlers = new Map<string, Handler[]>();

/// Registers `handler` for `command`; returns the unregister, for `$effect`.
export function onCommand(command: string, handler: Handler): () => void {
  const list = handlers.get(command) ?? [];
  list.push(handler);
  handlers.set(command, list);
  return () => {
    const now = handlers.get(command) ?? [];
    const i = now.lastIndexOf(handler);
    if (i >= 0) now.splice(i, 1);
  };
}

/// Several at once: `onCommands({ "session.pin": pin, "session.rename": rename })`.
export function onCommands(map: Record<string, Handler>): () => void {
  const offs = Object.entries(map).map(([c, h]) => onCommand(c, h));
  return () => offs.forEach((off) => off());
}

/// Runs `command` on the newest handler that takes it; false when none did.
export function runCommand(command: string): boolean {
  const list = handlers.get(command) ?? [];
  for (let i = list.length - 1; i >= 0; i--) {
    if (list[i]() !== false) return true;
  }
  return false;
}

/// Whether anything on screen offers `command` now.
export const offers = (command: string) => (handlers.get(command)?.length ?? 0) > 0;
