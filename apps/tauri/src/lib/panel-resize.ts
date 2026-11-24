// Panels you drag wider or narrower (the Mac's `PanelSplit` and `PanelLayout`): the main window's sidebar and the
// second tab of split view. Pure, so the sizes are tested; the views keep the width in localStorage.

/// The Mac's sizes (`PanelLayout`): the sidebar, the tab beside the main one, and what a conversation keeps.
export const LAYOUT = {
  sidebar: 280,
  sidebarMin: 220,
  sidebarMax: 420,
  split: 440,
  minimumPanel: 240,
  minimumConversation: 360,
  /// Room the drag line takes beside the panel.
  handle: 16,
} as const;

/// `wanted` kept at least `minimum`, and at most what leaves `rest` of `available` for the rest. Before the available
/// width is known (0), only the minimum applies. With too little room for both minimums the two shrink together in
/// proportion, so the panel never takes room the rest needs (`PanelSplit.width`).
export function panelWidth(wanted: number, minimum: number, available: number, rest: number): number {
  if (!(available > 0)) return Math.max(wanted, minimum);
  const share = (available * minimum) / Math.max(1, minimum + rest);
  const most = Math.max(available - rest, Math.min(minimum, share));
  return Math.round(Math.min(Math.max(wanted, minimum), most));
}

/// The width after dragging the line `offset` pixels from where it was at `start`. A line on the panel's leading edge
/// (a panel on the right) widens the panel when dragged to the left.
export function dragged(start: number, offset: number, handleOnLeading: boolean): number {
  return handleOnLeading ? start - offset : start + offset;
}

/// The sidebar's width: between its minimum and maximum, and never so wide the page keeps less than a conversation.
export function sidebarWidth(wanted: number, windowWidth: number): number {
  return Math.min(LAYOUT.sidebarMax, panelWidth(wanted, LAYOUT.sidebarMin, windowWidth, LAYOUT.minimumConversation));
}

/// A remembered width, or the default when none (or nonsense) was stored.
export function storedWidth(key: string, fallback: number): number {
  try {
    const n = Number(localStorage.getItem(key));
    return Number.isFinite(n) && n > 0 ? n : fallback;
  } catch {
    return fallback;
  }
}

export function storeWidth(key: string, width: number) {
  try { localStorage.setItem(key, String(Math.round(width))); } catch { /* remembering is a convenience */ }
}
