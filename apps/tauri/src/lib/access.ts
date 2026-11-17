// What Nook may do by itself from the chat (`brain::access` in core, `NookAccess` on the Mac), chosen in the composer:
// ask first, small things right away, or more by itself. Shift+Tab moves to the next level.
import type { Settings } from "./types";

export type NookAccess = "ask" | "small" | "more";

export const ACCESS_LEVELS: NookAccess[] = ["ask", "small", "more"];

/// The chosen level, or the one the old "small things right away" switch meant.
export function accessOf(settings: Pick<Settings, "nookAccess" | "autoRunSafe">): NookAccess {
  return settings.nookAccess ?? (settings.autoRunSafe ? "small" : "ask");
}

/// Shift+Tab: ask → small → more → ask.
export function nextAccess(level: NookAccess): NookAccess {
  return ACCESS_LEVELS[(ACCESS_LEVELS.indexOf(level) + 1) % ACCESS_LEVELS.length];
}
