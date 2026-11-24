// Opening the new-session screen on a project, from anywhere in the Agents tab: the project's name in a session's header
// (the Mac's `FolderCrumb`) and "Add project" at the head of the list (`AddProjectButton`).
import { agents } from "../../lib/agents.svelte";
import { workspaceApi } from "../../lib/workspace/api";
import { workspace } from "../../lib/workspace/store.svelte";

/// Shows the new-session screen in `path`: kept as the last project, so a screen that opens now starts there, and told
/// to one that is already open.
export async function openNewSessionIn(path: string): Promise<void> {
  const settings = workspace.settings;
  if (settings && settings.lastProject !== path) {
    await workspaceApi.saveSettings({ ...$state.snapshot(settings), lastProject: path });
    await workspace.refresh();
  }
  agents.select("new");
  requestAnimationFrame(() => window.dispatchEvent(new CustomEvent("nook-agents-project", { detail: path })));
}
