// How the session list is shown (the Mac's `InboxViewMenu`, and Settings › General › Session list): grouped by project
// (off by default, as on the Mac) and the working sessions on a shelf of their own. The Agents tab's filter menu and
// Settings both read and write it here, and a change in one tells the other at once.
export type AgentsView = { projectFolders: boolean; showWorking: boolean };

const KEY = "nook.agents.view";
const EVENT = "nook-agents-view";

export function loadAgentsView(): AgentsView {
  try { return { projectFolders: false, showWorking: true, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") }; } catch { return { projectFolders: false, showWorking: true }; }
}

export function saveAgentsView(next: AgentsView) {
  try { localStorage.setItem(KEY, JSON.stringify(next)); } catch { /* No storage: the choice lasts until the window closes. */ }
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(EVENT));
}

/** Calls `changed` when the other place changes the view; returns the way to stop listening. */
export function onAgentsView(changed: (view: AgentsView) => void): () => void {
  const listener = () => changed(loadAgentsView());
  window.addEventListener(EVENT, listener);
  return () => window.removeEventListener(EVENT, listener);
}
