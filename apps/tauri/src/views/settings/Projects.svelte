<script lang="ts">
  // Settings › Projects & pull requests › Projects (`WorkspaceSettingsSection`, part projects +
  // `ProjectSourceControlRows` + `ArchivedProjectsSection` on the Mac, AG-120): pick a project, give it a name,
  // icon, per-project defaults (auto-pull, submodules, coding agents), publish a local folder to GitHub, or
  // archive it. Every value marked Inherited follows the setting for all projects, and its reset button brings
  // that back.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import {
    permissionLabels,
    workspaceApi,
    type ExecutionMode,
    type IsolationMode,
    type PermissionPolicy,
    type ProjectOverride,
    type ProjectSettingsView,
    type PublishPlan,
    type RunProvider,
  } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import {
    PROJECT_TINTS,
    cleanEmoji,
    cleanMonogram,
    parseProjectIcon,
    projectInitials,
    storedProjectIcon,
    type ProjectIcon,
    type ProjectTint,
  } from "../../lib/project-icon";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ProjectIconView from "../../components/ui/ProjectIconView.svelte";
  import { tip } from "../../components/ui/tip";
  import PublishRepositoryModal from "./PublishRepositoryModal.svelte";

  type SubmodulesMode = "recursive" | "topLevel" | "skip";

  let error = $state<string | null>(null);
  let chosen = $state("");
  let view = $state<ProjectSettingsView | null>(null);
  let publishPlan = $state<PublishPlan | null>(null);
  let publishing = $state<PublishPlan | null>(null);
  let iconInput = $state("");
  let metaByPath = $state<Record<string, { archived: boolean; name: string | null; icon: ProjectIcon | null }>>({});

  $effect(() => {
    workspace.start();
  });

  // Your projects: the ones you added first, then the recent ones; archived ones only at the end of the page.
  const all = $derived([...new Set([...(workspace.settings?.favoriteProjects ?? []), ...(workspace.settings?.recentProjects ?? [])])]);
  $effect(() => {
    const paths = all;
    Promise.all(
      paths.map((p) =>
        workspaceApi.projectSettings(p).then((v) => [
          p,
          {
            archived: !!v.override.archived,
            name: v.override.name ?? null,
            icon: parseProjectIcon(v.override.icon),
          },
        ] as const),
      ),
    )
      .then((pairs) => (metaByPath = Object.fromEntries(pairs)))
      .catch(() => {});
  });
  const projects = $derived(all.filter((p) => !metaByPath[p]?.archived || p === chosen));
  const archived = $derived(all.filter((p) => metaByPath[p]?.archived));
  const shown = $derived(projects.includes(chosen) ? chosen : (projects[0] ?? ""));
  const folderName = (path: string) => path.split(/[\\/]/).filter(Boolean).pop() ?? path;
  const projectLabel = (path: string) => metaByPath[path]?.name?.trim() || folderName(path);

  $effect(() => {
    const path = shown;
    if (!path) {
      view = null;
      publishPlan = null;
      return;
    }
    workspaceApi.projectSettings(path).then((v) => (view = v)).catch((e) => (error = String(e)));
    workspaceApi.publishPlan(path).then((p) => (publishPlan = p)).catch(() => (publishPlan = null));
  });

  const providers = $derived(workspace.providers.filter((p) => p.supported));
  const policies = $derived<PermissionPolicy[]>(workspace.provider(view?.defaults.provider ?? "claude")?.capabilities.policies ?? ["acceptEdits"]);
  const currentIcon = $derived(parseProjectIcon(view?.override.icon));
  const agentsOff = $derived(view?.override.agentsOff ?? []);
  const enabledAgentCount = $derived(providers.filter((p) => !agentsOff.includes(p.provider)).length);

  function tintLabel(tint: ProjectTint): string {
    switch (tint) {
      case "mint":
        return tr("Mint", "Mint");
      case "amber":
        return tr("Amber", "Amber");
      case "coral":
        return tr("Koraal", "Coral");
      case "violet":
        return tr("Violet", "Violet");
      case "blue":
        return tr("Blauw", "Blue");
      case "music":
        return tr("Roze", "Rose");
    }
  }

  async function set(patch: Partial<ProjectOverride>) {
    if (!view) return;
    error = null;
    try {
      view = await workspaceApi.setProjectSettings(view.path, { ...view.override, ...patch });
      metaByPath = {
        ...metaByPath,
        [view.path]: {
          archived: !!view.override.archived,
          name: view.override.name ?? null,
          icon: parseProjectIcon(view.override.icon),
        },
      };
    } catch (e) {
      error = String(e);
    }
  }
  const own = (field: string) => !!view?.defaults.own.includes(field);

  function toggleAgent(provider: RunProvider) {
    if (!view) return;
    const current = new Set(view.override.agentsOff ?? []);
    if (current.has(provider)) current.delete(provider);
    else current.add(provider);
    set({ agentsOff: [...current] });
  }

  function currentMonogramLetters(): string {
    if (currentIcon?.kind === "monogram") return currentIcon.letters;
    return projectInitials(view ? folderName(view.path) : "");
  }

  function currentMonogramTint(): ProjectTint {
    if (currentIcon?.kind === "monogram") return currentIcon.tint;
    return "mint";
  }

  function setTint(tint: ProjectTint) {
    set({ icon: storedProjectIcon({ kind: "monogram", letters: currentMonogramLetters(), tint }) });
  }

  function applyIconInput() {
    const raw = iconInput.trim();
    iconInput = "";
    if (!raw) return;
    const emoji = cleanEmoji(raw);
    if (emoji) {
      set({ icon: storedProjectIcon({ kind: "emoji", emoji }) });
      return;
    }
    const letters = cleanMonogram(raw);
    if (letters) {
      set({ icon: storedProjectIcon({ kind: "monogram", letters, tint: currentMonogramTint() }) });
    }
  }

  async function chooseIconImage() {
    if (!view) return;
    const picked = await openDialog({
      directory: false,
      multiple: false,
      title: tr("Afbeelding kiezen…", "Choose image…"),
      filters: [{ name: "Images", extensions: ["png", "jpg", "jpeg", "gif", "webp", "ico", "svg", "bmp"] }],
    }).catch(() => null);
    if (typeof picked !== "string") return;
    error = null;
    try {
      const stored = await workspaceApi.saveProjectIcon(picked);
      await set({ icon: storedProjectIcon({ kind: "image", path: stored }) });
    } catch (e) {
      error = String(e);
    }
  }

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
    const updated = await workspaceApi.setProjectSettings(path, { ...v.override, archived: false });
    metaByPath = {
      ...metaByPath,
      [path]: {
        archived: false,
        name: updated.override.name ?? null,
        icon: parseProjectIcon(updated.override.icon),
      },
    };
  }
</script>

{#snippet inherited(field: string, reset: Partial<ProjectOverride>)}
  {#if own(field)}
    <button
      class="icon ghost"
      use:tip={tr("Gebruik de instelling voor alle projecten", "Use the setting for all projects")}
      aria-label={tr("Gebruik de instelling voor alle projecten", "Use the setting for all projects")}
      onclick={() => set(reset)}
    >
      <Ico name="rotate-ccw" size={12} />
    </button>
  {:else}
    <span class="inherited" use:tip={tr("Volgt de instelling voor alle projecten", "Follows the setting for all projects")}>
      {tr("Overgenomen", "Inherited")}
    </span>
  {/if}
{/snippet}

<h3>{tr("Nieuwe sessie", "New session")}</h3>
<p class="section-info">
  {tr(
    "Nieuwe sessies in dit project beginnen met deze waarden. Een waarde met Overgenomen volgt de instelling voor alle projecten; verander hem om dit project een eigen waarde te geven.",
    "New sessions in this project start with these values. A value marked Inherited follows the setting for all projects; change it to give this project its own.",
  )}
</p>
<div class="group">
  {#if !shown}
    <p class="note">
      {tr(
        "Projecten die je in Nook opent, staan hier. Elk kan eigen standaardwaarden hebben.",
        "Projects you open in Nook show up here. Each can set its own defaults.",
      )}
    </p>
  {:else}
    <label class="row">
      <span>{tr("Project", "Project")}</span>
      <select value={shown} onchange={(e) => (chosen = e.currentTarget.value)}>
        {#each projects as path (path)}<option value={path} title={path}>{projectLabel(path)}</option>{/each}
      </select>
    </label>
    {#if view}
      {@const d = view.defaults}
      <label
        class="row"
        use:tip={tr("De naam van het project in Nooks lijsten. Leeg: de naam van de map.", "The project's name in Nook's lists. Empty: the folder's name.")}
      >
        <span>{tr("Naam", "Name")}</span>
        <input
          class="field"
          placeholder={folderName(view.path)}
          value={view.override.name ?? ""}
          onchange={(e) => set({ name: e.currentTarget.value.trim() || null })}
        />
      </label>
      <div class="row">
        <span>{tr("Standaard-agent", "Default agent")}</span>
        <span class="value">
          {@render inherited("provider", { provider: null })}
          <select value={d.provider} onchange={(e) => set({ provider: e.currentTarget.value as RunProvider })}>
            {#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}
          </select>
        </span>
      </div>
      <div class="row">
        <span>{tr("Standaardmodus", "Default mode")}</span>
        <span class="value">
          {@render inherited("mode", { mode: null })}
          <select value={d.mode} onchange={(e) => set({ mode: e.currentTarget.value as ExecutionMode })}>
            <option value="agent">Agent</option>
            <option value="plan">Plan</option>
          </select>
        </span>
      </div>
      <div class="row">
        <span>{tr("Standaardrechten", "Default permissions")}</span>
        <span class="value">
          {@render inherited("permission", { permission: null })}
          <select value={d.permission} onchange={(e) => set({ permission: e.currentTarget.value as PermissionPolicy })}>
            {#each policies as p (p)}<option value={p}>{permissionLabels[p]}</option>{/each}
          </select>
        </span>
      </div>
      <div class="row">
        <span>{tr("Standaard-isolatie", "Default isolation")}</span>
        <span class="value">
          {@render inherited("isolation", { isolation: null })}
          <select value={d.isolation} onchange={(e) => set({ isolation: e.currentTarget.value as IsolationMode })}>
            <option value="worktree">{tr("Nieuwe Git-worktree", "New Git worktree")}</option>
            <option value="folder">{tr("Huidige map", "Current folder")}</option>
          </select>
        </span>
      </div>
      <div class="row">
        <span>{tr("Prefix voor branches", "Branch prefix")}</span>
        <span class="value">
          {@render inherited("branchPrefix", { branchPrefix: null })}
          <input
            class="prefix"
            value={d.branchPrefix}
            aria-label={tr("Prefix voor branches", "Branch prefix")}
            onchange={(e) => set({ branchPrefix: e.currentTarget.value.trim() || null })}
          />
          <span class="example">{tr("bijv. {prefix}/fix-login-3fa2", "e.g. {prefix}/fix-login-3fa2", { prefix: d.branchPrefix || "nook" })}</span>
        </span>
      </div>
      <div class="row">
        <span>{tr("Submodules", "Submodules")}</span>
        <span class="value">
          {@render inherited("submodules", { submodules: null })}
          <select value={d.submodules} onchange={(e) => set({ submodules: e.currentTarget.value as SubmodulesMode })}>
            <option value="recursive">{tr("Alle, recursief", "All, recursively")}</option>
            <option value="topLevel">{tr("Alleen het bovenste niveau", "Top level only")}</option>
            <option value="skip">{tr("Overslaan", "Skip")}</option>
          </select>
        </span>
      </div>
      <div class="row">
        <span>{tr("Standaardbranch bijhouden", "Keep the default branch up to date")}</span>
        <span class="value">
          {@render inherited("autoPull", { autoPull: null })}
          <select
            value={d.autoPull ? "on" : "off"}
            aria-label={tr("Standaardbranch bijhouden", "Keep the default branch up to date")}
            onchange={(e) => set({ autoPull: e.currentTarget.value === "on" })}
          >
            <option value="on">{tr("Aan", "On")}</option>
            <option value="off">{tr("Uit", "Off")}</option>
          </select>
        </span>
      </div>
      <label class="row stacked">
        <span class="stack-head">
          {tr("Eigen regels voor titels", "Your own rules for titles")}
          {@render inherited("titleInstructions", { titleInstructions: null })}
        </span>
        <textarea
          rows="2"
          placeholder={tr("Begin met het ticketnummer, schrijf in het Engels", "Start with the ticket number, write in English")}
          value={view.override.titleInstructions ?? ""}
          onchange={(e) => set({ titleInstructions: e.currentTarget.value.trim() || null })}
        ></textarea>
      </label>
      <label class="row stacked">
        <span class="stack-head">
          {tr("Instructies voor elke agent", "Instructions for every agent")}
          {@render inherited("agentInstructions", { agentInstructions: null })}
        </span>
        <textarea
          rows="3"
          placeholder={tr(
            "Regels die elke agent hier volgt, bijv. “Draai de tests voor je commit.”",
            "Rules every agent follows here, e.g. “Run the tests before you commit.”",
          )}
          value={view.override.agentInstructions ?? d.agentInstructions}
          onchange={(e) => set({ agentInstructions: e.currentTarget.value.trim() || null })}
        ></textarea>
      </label>

      <div
        class="row stacked"
        use:tip={tr(
          "Kies welke coding-agents voor sessies in dit project worden aangeboden.",
          "Choose which coding agents are offered for sessions in this project.",
        )}
      >
        <div class="stack-between">
          <span>{tr("Coding-agents", "Coding agents")}</span>
          <span class="inherited">
            {agentsOff.length === 0
              ? tr("Alle", "All")
              : tr("{on} van {total}", "{on} of {total}", { on: enabledAgentCount, total: providers.length })}
          </span>
        </div>
        <div class="agent-chips">
          {#each providers as p (p.provider)}
            {@const active = !agentsOff.includes(p.provider)}
            <button
              type="button"
              class="small chip-toggle"
              class:active
              aria-pressed={active}
              onclick={() => toggleAgent(p.provider)}
            >
              {p.name}
            </button>
          {/each}
        </div>
      </div>

      <div
        class="row"
        use:tip={tr(
          "Getoond naast dit project in Nooks lijsten. Typ een emoji of twee letters, kies een kleur of kies een afbeelding.",
          "Shown next to this project in Nook's lists. Type an emoji or two letters, choose a color, or pick an image.",
        )}
      >
        <span>{tr("Project-icoon", "Project icon")}</span>
        <span class="value icon-controls">
          <ProjectIconView icon={currentIcon} name={folderName(view.path)} size={22} />
          <input
            class="emoji-field"
            type="text"
            placeholder={tr("Emoji of letters", "Emoji or letters")}
            aria-label={tr("Emoji of letters", "Emoji or letters")}
            bind:value={iconInput}
            onchange={applyIconInput}
            onkeydown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                applyIconInput();
              }
            }}
          />
          <select
            aria-label={tr("Kleur", "Color")}
            value={currentMonogramTint()}
            onchange={(e) => setTint(e.currentTarget.value as ProjectTint)}
          >
            {#each PROJECT_TINTS as tint (tint)}
              <option value={tint}>{tintLabel(tint)}</option>
            {/each}
          </select>
          <button type="button" class="small" onclick={chooseIconImage}>{tr("Afbeelding kiezen…", "Choose image…")}</button>
          {#if currentIcon}
            <button type="button" class="small" onclick={() => set({ icon: null })}>{tr("Herstel", "Reset")}</button>
          {/if}
        </span>
      </div>

      {#if publishPlan}
        <div
          class="row"
          use:tip={tr(
            "Maak een nieuwe GitHub-repository aan voor dit lokale project en push de huidige branch.",
            "Create a new GitHub repository for this local project and push its current branch.",
          )}
        >
          <span>{tr("Publiceren op GitHub", "Publish to GitHub")}</span>
          <button type="button" class="small" onclick={() => (publishing = publishPlan)}>
            {tr("Publiceer", "Publish")}
          </button>
        </div>
      {/if}

      <label class="row">
        <span>{tr("Gearchiveerd", "Archived")}</span>
        <input
          type="checkbox"
          role="switch"
          checked={!!view.override.archived}
          onchange={(e) => set({ archived: e.currentTarget.checked })}
        />
      </label>
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
  <p class="section-info">
    {tr(
      "Een gearchiveerd project staat niet meer in de projectkiezers. Sessies, instellingen en bestanden blijven; zet het uit om het project terug te halen.",
      "An archived project is left out of the project pickers. Its sessions, settings and files stay; switch it off to bring the project back.",
    )}
  </p>
  <div class="group">
    {#each archived as path (path)}
      <div class="row">
        <span class="archived-name" use:tip={path}>
          <ProjectIconView icon={metaByPath[path]?.icon ?? null} name={folderName(path)} size={16} />
          <span>{projectLabel(path)}</span>
        </span>
        <span class="value">
          <button class="small" onclick={() => (chosen = path)}>{tr("Instellingen", "Settings")}</button>
          <button class="small" onclick={() => restore(path)}>{tr("Terugzetten", "Restore")}</button>
        </span>
      </div>
    {/each}
  </div>
{/if}

{#if publishing}
  <PublishRepositoryModal
    plan={publishing}
    ondone={(url) => {
      publishing = null;
      if (url) publishPlan = null;
    }}
  />
{/if}

<style>
  .value { display: inline-flex; align-items: center; gap: var(--space-8); flex-wrap: wrap; }
  .inherited { font: var(--text-detail); color: var(--text3); }
  .example { font: var(--text-detail); color: var(--text2); white-space: nowrap; }
  .field { width: 220px; }
  .prefix { width: 160px; }
  .emoji-field { width: 120px; }
  .stack-head { display: inline-flex; align-items: center; gap: var(--space-8); }
  .stack-between { display: flex; align-items: center; justify-content: space-between; width: 100%; gap: var(--space-8); }
  .stacked textarea { width: 100%; resize: vertical; font: var(--text-body); }
  .icon { display: grid; place-items: center; width: 22px; height: 22px; padding: 0; border: none; background: none; color: var(--text3); }
  .icon:hover:not(:disabled) { color: var(--paper); background: none; }
  .agent-chips { display: flex; flex-wrap: wrap; gap: var(--space-6); }
  .chip-toggle { opacity: 0.55; }
  .chip-toggle.active { opacity: 1; border-color: var(--iris); color: var(--paper); }
  .icon-controls { justify-content: flex-end; }
  .archived-name { display: inline-flex; align-items: center; gap: var(--space-8); min-width: 0; }
</style>
