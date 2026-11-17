// The logic behind the shared components in `components/ui/` that has rules of its own, apart from the view so tests can
// drive it: the tooltip's timing and placement (`NookTooltip.swift`), the copy button's moment (`CopiedMoment`) and a
// path cut in the middle (`IconDetailRow`'s detail lines).

/** The Mac's tooltip timing: open after a 150 ms rest, swap at once while the pointer moves on within 400 ms. */
export const TIP_REST_MS = 150;
export const TIP_SWAP_MS = 400;

/**
 * When a tooltip opens. `enter` returns the delay before the tip shows; `leave` remembers when the last one closed, so
 * moving to the next control within `TIP_SWAP_MS` shows its tip without the rest.
 */
export class TipClock {
  private closedAt = -Infinity;
  private open = false;
  enter(now: number): number {
    return this.open || now - this.closedAt <= TIP_SWAP_MS ? 0 : TIP_REST_MS;
  }
  shown() {
    this.open = true;
  }
  leave(now: number) {
    if (this.open) this.closedAt = now;
    this.open = false;
  }
  /** A click, scroll or key closes the tip and the next one waits for its rest again. */
  dismiss() {
    this.open = false;
    this.closedAt = -Infinity;
  }
}

export interface Box { left: number; top: number; width: number; height: number }
export type TipEdge = "top" | "bottom";

/**
 * Where a tip of `size` goes for a control at `anchor` in a window of `view`: centered on the preferred edge, flipped
 * when it does not fit there, and clamped `margin` inside the window's sides.
 */
export function placeTip(anchor: Box, size: { width: number; height: number }, view: { width: number; height: number },
  edge: TipEdge = "bottom", gap = 6, margin = 8): { left: number; top: number; edge: TipEdge } {
  const below = anchor.top + anchor.height + gap;
  const above = anchor.top - gap - size.height;
  let side = edge;
  if (side === "bottom" && below + size.height > view.height - margin && above >= margin) side = "top";
  else if (side === "top" && above < margin && below + size.height <= view.height - margin) side = "bottom";
  const top = side === "bottom" ? below : above;
  const centered = anchor.left + anchor.width / 2 - size.width / 2;
  const left = Math.max(margin, Math.min(centered, view.width - margin - size.width));
  return { left: Math.round(left), top: Math.round(Math.max(margin, top)), edge: side };
}

/** How long a copy button shows its checkmark (`CopiedMoment`). */
export const COPIED_MS = 1500;

/** The "Copied" moment of a copy button: a second copy restarts it, and it ends by itself. */
export class CopiedMoment {
  private timer: ReturnType<typeof setTimeout> | undefined;
  constructor(private changed: (copied: boolean) => void, private duration = COPIED_MS) {}
  copied() {
    if (this.timer) clearTimeout(this.timer);
    this.changed(true);
    this.timer = setTimeout(() => {
      this.timer = undefined;
      this.changed(false);
    }, this.duration);
  }
  stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
  }
}

/** A long line cut in the middle with "…", so a path keeps its start and its file name. */
export function cutMiddle(text: string, max: number): string {
  if (max < 3 || text.length <= max) return text;
  const keep = max - 1;
  const head = Math.floor(keep / 2); // the end (a file name) gets the extra character
  return `${text.slice(0, head)}…${text.slice(text.length - (keep - head))}`;
}
