import type { Component } from "svelte";

export const routeTitles = {
  chat: "Chat", agents: "Agents", workspace: "Workspace", companion: "Companion", settings: "Settings",
};
export type Route = keyof typeof routeTitles;

export function parseRoute(value: string | null): Route {
  switch (value) {
    case "agents": case "workspace": case "companion": case "settings": return value;
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

export const routeViews = {
  agents: retryableView(() => import("../views/Agents.svelte")),
  workspace: retryableView(() => import("../views/Workspace.svelte")),
  companion: retryableView(() => import("../views/companion/Companion.svelte")),
  settings: retryableView(() => import("../views/Settings.svelte")),
};
