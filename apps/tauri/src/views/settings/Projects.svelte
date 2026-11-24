<script lang="ts">
  // Settings › Projects & pull requests › Projects (`WorkspaceSettingsSection`, part projects, on the Mac): pick a
  // project, give it a name, and set what a new session there starts with; every value marked Inherited follows the
  // setting for all projects (Settings › Sessions), and its reset button brings that back. Archived projects are left
  // out of the pickers and listed at the end. Stored per project in the workspace settings
  // (`workspace_project_settings`, `workspace_set_project_settings`); the new-session screen reads `defaults`.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import {
    permissionLabels, workspaceApi, type ExecutionMode, type IsolationMode, type PermissionPolicy, type ProjectOverride, type ProjectSettingsView,
    type RunProvider,
  } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { tip } from "../../components/ui/tip";

  let error = $state<string | null>(null);
  let chosen = $state("");
  let view = $state<ProjectSettingsView | null>(null);
  let archivedViews = $state<Record<string, boolean>>({});

  $effect(() => {
    workspace.start();
  });

  // Your projects: the ones you added first, then the recent ones; archived ones only at the end of the page.
  const all = $derived([...new Set([...(workspace.settings?.favoriteProjects ?? []), ...(workspace.settings?.recentProjects ?? [])])]);
  $effect(() => {
    const paths = all;
    Promise.all(paths.map((p) => workspaceApi.projectSettings(p).then((v) => [p, !!v.override.archived] as const)))
      .then((pairs) => (archivedViews = Object.fromEntries(pairs)))
      .catch(() => {});
  });
  const projects = $derived(all.filter((p) => !archivedViews[p] || p === chosen));
  const archived = $derived(all.filter((p) => archivedViews[p]));
  const shown = $derived(projects.includes(chosen) ? chosen : (projects[0] ?? ""));
  const folderName = (path: string) => path.split(/[\\/]/).filter(Boolean).pop() ?? path;

  $effect(() => {
    const path = shown;
    if (!path) { view = null; return; }
    workspaceApi.projectSettings(path).then((v) => (view = v)).catch((e) => (error = String(e)));
  });

  const providers = $derived(workspace.providers.filter((p) => p.supported));
  const policies = $derived<PermissionPolicy[]>(workspace.provider(view?.defaults.provider ?? "claude")?.capabilities.policies ?? ["acceptEdits"]);

  async function set(patch: Partial<ProjectOverride>) {
    if (!view) return;
    error = null;
    try {
      view = await workspaceApi.setProjectSettings(view.path, { ...view.override, ...patch });
      if ("archived" in patch) archivedViews = { ...archivedViews, [view.path]: !!view.override.archived };
    } catch (e) {
      error = String(e);
    }
  }
  const own = (field: string) => !!view?.defaults.own.includes(field);

  async function add() {
    const picked = await openDialog({ directory: true, multiple: false, title: tr("Project toevoegen", "Add project") }).catch(() => null);
    if (typeof picked !== "string") return;
    try {
      if (!(workspace.settings?.favoriteProjects ?? []).includes(picked)) await workspaceApi.toggleFavoriteProject(picked);
      await workspace.refresh();
      chosen = picked;
    } catch (e) {
      error = String(e);
    }
  }

  async function restore(path: string) {
    const v = await workspaceApi.projectSettings(path);
    await workspaceApi.setProjectSettings(path, { ...v.override, archived: false });
    archivedViews = { ...archivedViews, [path]: false };
  }
</script>

{#snippet inherited(field: string, reset: Partial<ProjectOverride>)}
  {#if own(field)}
    <button class="icon ghost" use:tip={tr("Gebruik de instelling voor alle projecten", "Use the setting for all projects")} aria-label={tr("Gebruik de instelling voor alle projecten", "Use the setting for all projects")} onclick={() => set(reset)}><Ico name="rotate-ccw" size={12} /></button>
  {:else}
    <span class="inherited" use:tip={tr("Volgt de instelling voor alle projecten", "Follows the setting for all projects")}>{tr("Overgenomen", "Inherited")}</span>
  {/if}
{/snippet}

<h3>{tr("Nieuwe sessie", "New session")}</h3>
<p class="section-info">{tr("Nieuwe sessies in dit project beginnen met deze waarden. Een waarde met Overgenomen volgt de instelling voor alle projecten; verander hem om dit project een eigen waarde te geven.", "New sessions in this project start with these values. A value marked Inherited follows the setting for all projects; change it to give this project its own.")}</p>
<div class="group">
  {#if !shown}
    <p class="note">{tr("Projecten die je in Nook opent, staan hier. Elk kan eigen standaardwaarden hebben.", "Projects you open in Nook show up here. Each can set its own defaults.")}</p>
  {:else}
    <label class="row"><span>{tr("Project", "Project")}</span>
      <select value={shown} onchange={(e) => (chosen = e.currentTarget.value)}>
        {#each projects as path (path)}<option value={path} title={path}>{folderName(path)}</option>{/each}
      </select>
    </label>
    {#if view}
      {@const d = view.defaults}
      <label class="row" use:tip={tr("De naam van het project in Nooks lijsten. Leeg: de naam van de map.", "The project's name in Nook's lists. Empty: the folder's name.")}>
        <span>{tr("Naam", "Name")}</span>
        <input class="field" placeholder={folderName(view.path)} value={view.override.name ?? ""} onchange={(e) => set({ name: e.currentTarget.value.trim() || null })} />
      </label>
      <div class="row"><span>{tr("Standaard-agent", "Default agent")}</span>
        <span class="value">{@render inherited("provider", { provider: null })}
          <select value={d.provider} onchange={(e) => set({ provider: e.currentTarget.value as RunProvider })}>{#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}</select></span>
      </div>
      <div class="row"><span>{tr("Standaardmodus", "Default mode")}</span>
        <span class="value">{@render inherited("mode", { mode: null })}
          <select value={d.mode} onchange={(e) => set({ mode: e.currentTarget.value as ExecutionMode })}><option value="agent">Agent</option><option value="plan">Plan</option></select></span>
      </div>
      <div class="row"><span>{tr("Standaardrechten", "Default permissions")}</span>
        <span class="value">{@render inherited("permission", { permission: null })}
          <select value={d.permission} onchange={(e) => set({ permission: e.currentTarget.value as PermissionPolicy })}>{#each policies as p (p)}<option value={p}>{permissionLabels[p]}</option>{/each}</select></span>
      </div>
      <div class="row"><span>{tr("Standaard-isolatie", "Default isolation")}</span>
        <span class="value">{@render inherited("isolation", { isolation: null })}
          <select value={d.isolation} onchange={(e) => set({ isolation: e.currentTarget.value as IsolationMode })}><option value="worktree">{tr("Nieuwe Git-worktree", "New Git worktree")}</option><option value="folder">{tr("Huidige map", "Current folder")}</option></select></span>
      </div>
      <div class="row"><span>{tr("Prefix voor branches", "Branch prefix")}</span>
        <span class="value">{@render inherited("branchPrefix", { branchPrefix: null })}
          <input class="prefix" value={d.branchPrefix} aria-label={tr("Prefix voor branches", "Branch prefix")} onchange={(e) => set({ branchPrefix: e.currentTarget.value.trim() || null })} />
          <span class="example">{tr("bijv. {prefix}/fix-login-3fa2", "e.g. {prefix}/fix-login-3fa2", { prefix: d.branchPrefix || "nook" })}</span></span>
      </div>
      <label class="row stacked">
        <span class="stack-head">{tr("Eigen regels voor titels", "Your own rules for titles")} {@render inherited("titleInstructions", { titleInstructions: null })}</span>
        <textarea rows="2" placeholder={tr("Begin met het ticketnummer, schrijf in het Engels", "Start with the ticket number, write in English")} value={view.override.titleInstructions ?? ""}
          onchange={(e) => set({ titleInstructions: e.currentTarget.value.trim() || null })}></textarea>
      </label>
      <label class="row stacked">
        <span class="stack-head">{tr("Instructies voor elke agent", "Instructions for every agent")} {@render inherited("agentInstructions", { agentInstructions: null })}</span>
        <textarea rows="3" placeholder={tr("Regels die elke agent hier volgt, bijv. “Draai de tests voor je commit.”", "Rules every agent follows here, e.g. “Run the tests before you commit.”")} value={view.override.agentInstructions ?? d.agentInstructions}
          onchange={(e) => set({ agentInstructions: e.currentTarget.value.trim() || null })}></textarea>
      </label>
      <label class="row"><span>{tr("Gearchiveerd", "Archived")}</span><input type="checkbox" role="switch" checked={!!view.override.archived} onchange={(e) => set({ archived: e.currentTarget.checked })} /></label>
    {/if}
  {/if}
  <div class="row">
    <span>{tr("Nieuw project uit een map", "New project from a folder")}</span>
    <button class="small" onclick={add}>{tr("Project toevoegen", "Add project")}</button>
  </div>
</div>
{#if error}<p class="note err">{error}</p>{/if}

{#if archived.length}
  <h3>{tr("Gearchiveerde projecten", "Archived projects")}</h3>
  <p class="section-info">{tr("Een gearchiveerd project staat niet meer in de projectkiezers. Sessies, instellingen en bestanden blijven; zet het uit om het project terug te halen.", "An archived project is left out of the project pickers. Its sessions, settings and files stay; switch it off to bring the project back.")}</p>
  <div class="group">
    {#each archived as path (path)}
      <div class="row">
        <span use:tip={path}>{folderName(path)}</span>
        <span class="value"><button class="small" onclick={() => (chosen = path)}>{tr("Instellingen", "Settings")}</button><button class="small" onclick={() => restore(path)}>{tr("Terugzetten", "Restore")}</button></span>
      </div>
    {/each}
  </div>
{/if}

<style>
  .value { display: inline-flex; align-items: center; gap: var(--space-8); }
  .inherited { font: var(--text-detail); color: var(--text3); }
  .example { font: var(--text-detail); color: var(--text2); white-space: nowrap; }
  .field { width: 220px; }
  .prefix { width: 160px; }
  .stack-head { display: inline-flex; align-items: center; gap: var(--space-8); }
  .stacked textarea { width: 100%; resize: vertical; font: var(--text-body); }
  .icon { display: grid; place-items: center; width: 22px; height: 22px; padding: 0; border: none; background: none; color: var(--text3); }
  .icon:hover:not(:disabled) { color: var(--paper); background: none; }
</style>
