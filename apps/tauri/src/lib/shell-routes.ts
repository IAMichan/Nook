import type { Component } from "svelte";

/// The main window's pages, with their (English) names. Main shows them translated.
export const routeTitles = {
  chat: "Nook", chats: "Chats", agents: "Agents", music: "Music", workspace: "Workspace", games: "Gamer Mode", companion: "Companion", settings: "Settings",
};
export type Route = keyof typeof routeTitles;

export function parseRoute(value: string | null): Route {
  switch (value) {
    case "agents": case "chats": case "music": case "workspace": case "games": case "companion": case "settings": return value;
    default: return "chat";
  }
}

export function resumeRoute(): Route {
  try {
    const route = sessionStorage.getItem("nook.resumeRoute");
    sessionStorage.removeItem("nook.resumeRoute");
    return parseRoute(route);
  } catch {
    return "chat";
  }
}

export function reloadRoute(route: Route) {
  // Browsers can cache a failed module import for this document's lifetime.
  // A reload clears that cache and retries the same route, without a reload loop.
  try { sessionStorage.setItem("nook.resumeRoute", route); } catch { /* Storage may be unavailable. */ }
  window.location.reload();
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any -- a view takes the props its caller passes (`LazyView.props`)
export type ViewModule = { default: Component<any> };

// Share successful imports across visits, but let a failed download be retried.
export function retryableView(load: () => Promise<ViewModule>): () => Promise<ViewModule> {
  let pending: Promise<ViewModule> | undefined;
  return () => pending ??= load().catch((error: unknown) => {
    pending = undefined;
    throw error;
  });
}

export const routeViews: Partial<Record<Route, () => Promise<ViewModule>>> = {
  agents: retryableView(() => import("../views/Agents.svelte")),
  workspace: retryableView(() => import("../views/Workspace.svelte")),
  games: retryableView(() => import("../views/games/GamerMode.svelte")),
  companion: retryableView(() => import("../views/companion/Companion.svelte")),
  settings: retryableView(() => import("../views/Settings.svelte")),
};


/// The Settings subjects and the names that lead to them live in `settings-pages.ts`.
export { settingsSection, settingsSections, type SettingsSectionId } from "./settings-pages";

/// Folds case and accents, so "geluid" finds "Geluid" and "reglages" finds "Réglages".
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

/// True when every word of the query is in one of the texts (a page's name, its group). An empty query matches all.
export function matchesSearch(query: string, ...texts: string[]): boolean {
  const words = fold(query).split(/\s+/).filter(Boolean);
  const haystack = fold(texts.join(" "));
  return words.every((w) => haystack.includes(w));
}

/// Leaves Settings for the page it was opened from. Settings takes the whole main window, as the Mac's Settings window
/// does, so its sidebar's Back (and Escape) asks the shell (`Main.svelte`) to go back.
export const LEAVE_SETTINGS = "nook-leave-settings";
export function leaveSettings() {
  window.dispatchEvent(new Event(LEAVE_SETTINGS));
}
