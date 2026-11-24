// Hold Ctrl+Q to quit (the Mac's `QuitHold`): a press shows "Hold Ctrl+Q to quit Nook"; held for a second it says
// "Release to quit Nook", and letting go then quits. Letting go earlier, or another key first, takes the hint away.
// A browser sends key-up reliably, so this is the Mac's machine without its repeat-based guessing. Pure, for tests.

export const HOLD_MS = 1000;
export type QuitHint = "hold" | "release" | "hidden";
export type QuitInput = "pressed" | "released" | "otherKey" | "check";
export interface QuitOutput { hint?: QuitHint; quit?: boolean; checkIn?: number }

export class QuitHold {
  private since: number | null = null;
  private armed = false;

  get idle(): boolean { return this.since === null && !this.armed; }

  handle(input: QuitInput, now: number): QuitOutput {
    if (this.armed) {
      if (input === "released") { this.armed = false; return { hint: "hidden", quit: true }; }
      return {};
    }
    if (input === "pressed") {
      if (this.since !== null) return {};
      this.since = now;
      return { hint: "hold", checkIn: HOLD_MS };
    }
    if (this.since === null) return {};
    if (input === "check") {
      if (now - this.since < HOLD_MS) return { checkIn: HOLD_MS - (now - this.since) };
      this.since = null;
      this.armed = true;
      return { hint: "release" };
    }
    this.since = null;
    return { hint: "hidden" };
  }
}

/// The key event's part in the hold: Ctrl+Q down (a repeat counts as nothing new), Q or Ctrl up, or another key.
export function quitInput(e: Pick<KeyboardEvent, "type" | "key" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey" | "repeat">): QuitInput | null {
  const q = e.key.toLowerCase() === "q";
  if (e.type === "keydown") {
    if (q && (e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey) return e.repeat ? null : "pressed";
    if (e.key === "Control" || e.key === "Meta") return null;
    return "otherKey";
  }
  if (e.type === "keyup" && (q || e.key === "Control" || e.key === "Meta")) return "released";
  return null;
}
