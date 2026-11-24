// Split view (the Mac's `PanelSplitChoice`): a second tab beside the one you are on, so you keep an eye on your chats
// or the music while you work in another tab. Chosen from the button in the sidebar's head, remembered; the tab you
// are on never shows a second time beside itself. A tab can also go into a window of its own (`TabWindowController`),
// and those windows open again after a restart.
import type { Route } from "./shell-routes";

export const SPLIT_KEY = "nook.panel.split";
export const SPLIT_WIDTH_KEY = "nook.panel.splitWidth";
export const TAB_WINDOWS_KEY = "nook.panel.tabWindows";
/// How wide the second tab starts (`PanelLayout.split`).
export const LAYOUT_SPLIT = 440;

/// The tabs that can sit beside another one, or in a window of their own.
export const SPLIT_CHOICES = ["chat", "agents", "chats", "music"] as const satisfies readonly Route[];
export type SplitTab = (typeof SPLIT_CHOICES)[number];

export function isSplitTab(value: unknown): value is SplitTab {
  return typeof value === "string" && (SPLIT_CHOICES as readonly string[]).includes(value);
}

/// The tab beside `current` for the stored choice; null while split view is off or the choice is the tab itself.
export function splitSide(stored: string | null, current: Route): SplitTab | null {
  return isSplitTab(stored) && stored !== current ? stored : null;
}

/// The tab to show for a request to open `tab` while `current` is the main tab: `current` itself when `tab` already
/// shows beside it, so a chat opened from search or a notice opens in that pane instead of closing split view.
export function splitLanding(tab: Route, current: Route, stored: string | null): Route {
  return splitSide(stored, current) === tab ? current : tab;
}

/// The marks of the tabs (`PanelSplitChoice.symbol`), as the sidebar's tab bar shows them.
export const TAB_MARKS: Record<SplitTab, string> = {
  chat: "sparkles",
  agents: "terminal",
  chats: "messages-square",
  music: "audio-waveform",
};

/// The tabs torn off into a window of their own, in the order they were opened; read at launch to open them again.
export function storedTabWindows(text: string | null): SplitTab[] {
  try {
    const list = JSON.parse(text ?? "[]");
    return Array.isArray(list) ? [...new Set(list.filter(isSplitTab))] : [];
  } catch {
    return [];
  }
}

/// The window label of a torn-off tab (also its key in the list above).
export const tabWindowLabel = (tab: SplitTab) => `tab-${tab}`;

/// The tab a torn-off window shows, from its URL (`?tab=chats`); null in the main window.
export function tabFromLocation(search: string): SplitTab | null {
  const tab = new URLSearchParams(search).get("tab");
  return isSplitTab(tab) ? tab : null;
}
