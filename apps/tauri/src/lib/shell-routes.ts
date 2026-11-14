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

export type ViewModule = { default: Component };

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


/// The Settings pages, in the order of the sidebar (`SettingsSection` on the Mac).
export const settingsSections = [
  "overview", "general", "appearance", "voice", "games", "shortcuts", "brain", "assistant", "memory", "instructions", "autocomplete", "agents",
  "archive", "accounts", "companion", "privacy", "maintenance", "about",
] as const;
export type SettingsSectionId = (typeof settingsSections)[number];

/// Other names a button elsewhere may use for a Settings page.
const sectionAliases: Record<string, SettingsSectionId> = {
  start: "overview", connections: "accounts", sound: "voice", iphone: "companion", gamer: "games",
  look: "appearance", theme: "appearance", keys: "shortcuts", keybindings: "shortcuts", updates: "maintenance",
};

/// The Settings page a stored or requested name stands for; Overview for anything unknown.
export function settingsSection(value: string | null | undefined): SettingsSectionId {
  if (!value) return "overview";
  if ((settingsSections as readonly string[]).includes(value)) return value as SettingsSectionId;
  return Object.prototype.hasOwnProperty.call(sectionAliases, value) ? sectionAliases[value] : "overview";
}

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
