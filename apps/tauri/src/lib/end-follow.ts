// The rules for following the end of a conversation that grows while you read it (the Mac's `ScrollModel` and
// `TimelineReadingAnchor`, learned from t3code's `timelineViewport.ts`):
//
// - Only your own input up lets go of the end: a wheel step, a key, a drag of the scrollbar or a swipe that moves the
//   view up. Where the view happens to be never does, because while text streams in the end flickers out of reach
//   for a frame and a step that started there would otherwise be pulled straight back down.
// - Only your own input down that reaches the end follows again (or "To the end", or sending a message).
// - While you read back, the row you are reading stays where it is when rows above or below it change size.
// - While the agent works, the content never shrinks under a view that follows the end: a group folding up would
//   otherwise drop everything down and back up ("bouncing").

/** How close to the end still counts as at the end, in px. */
export const END_SLACK = 24;
/** How far from the end before "To the end" shows, in px. */
export const FAR = 120;

export type Metrics = { scrollTop: number; scrollHeight: number; clientHeight: number };

/** The distance between the bottom of the view and the end of the content. */
export function gap(m: Metrics): number {
  return Math.max(0, m.scrollHeight - m.scrollTop - m.clientHeight);
}

export function nearEnd(m: Metrics, slack = END_SLACK): boolean {
  return gap(m) <= slack;
}

/** What a step of your own does to following: up lets go, down to the end follows again, anything else keeps it. */
export function reaction(following: boolean, direction: "up" | "down" | "none", after: Metrics): boolean {
  if (direction === "up") return false;
  if (direction === "down" && nearEnd(after)) return true;
  return following;
}

/** The direction of a key that scrolls, or null for any other key. */
export function keyDirection(key: string, shift = false): "up" | "down" | null {
  switch (key) {
    case "ArrowUp":
    case "PageUp":
    case "Home":
      return "up";
    case "ArrowDown":
    case "PageDown":
    case "End":
      return "down";
    case " ":
      return shift ? "up" : "down";
    default:
      return null;
  }
}

/** The height to hold the content at: the highest it reached while held, otherwise its own. */
export function heldHeight(previous: number, natural: number, holding: boolean): number {
  return holding ? Math.max(previous, natural) : natural;
}

/** How far to scroll to keep the row you read in its place, given where it was and where it is now. */
export function anchorCorrection(before: number, now: number): number {
  const delta = now - before;
  return Math.abs(delta) < 0.5 ? 0 : delta;
}
