<script lang="ts">
  // Een sessie starten (`NewSessionComposer` op de Mac): één vraag, één veld en een paar rustige keuzes eronder.
  // "Wat zullen we bouwen in nook?" — typ de opdracht, druk op Enter. Agent en account, model, modus, rechten, denkniveau, waar hij
  // werkt (deze map of een nieuwe worktree) en de branch waar hij van start staan al op je laatste keuzes in deze map. Titel,
  // branchnaam en de plek van de worktree volgen vanzelf.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agentApi, type AgentProfile } from "../../../lib/agents";
  import { agents } from "../../../lib/agents.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import {
    effortLabels, effortLevels, isActive, permissionHelp, permissionLabels, projectName, workspaceApi, type NewRunConfig, type PermissionPolicy, type ProjectInfo,
    type RunProvider,
  } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";

  let { onstarted }: { onstarted: (id: string) => void } = $props();

  let config = $state<NewRunConfig>({
    title: "", task: "", provider: "claude", profileId: "claude", model: "", mode: "agent", permission: "acceptEdits",
    isolation: "worktree", projectPath: "", baseBranch: "", branchName: "", worktreeRoot: "", instructions: "", effort: null,
  });
  let profiles = $state<AgentProfile[]>([]);
  let project = $state<ProjectInfo | null>(null);
  let inspecting = $state(false);
  let starting = $state(false);
  let error = $state<string | null>(null);
  let allowShared = $state(false);
  let showClone = $state(false);
  let cloneUrl = $state("");
  let cloning = $state(false);
  let menu = $state<"" | "project" | "agent" | "permission" | "effort" | "where" | "branch">("");
  let branchQuery = $state("");
  let textarea = $state<HTMLTextAreaElement>();
  let selectionRequest = 0;
  let prepared = false;
  /// The folder whose choices the composer shows.
  let folderApplied = "";

  const settings = $derived(workspace.settings);
  const runnable = $derived(workspace.providers.filter((p) => p.supported));
  const connected = $derived(runnable.filter((p) => p.executable));
  const provider = $derived(workspace.provider(config.provider));
  const policies = $derived<PermissionPolicy[]>(provider?.capabilities.policies ?? ["acceptEdits"]);
  const profilesFor = (p: RunProvider) => profiles.filter((x) => x.kind === p);
  const profile = $derived(profiles.find((p) => p.id === config.profileId));
  const levels = $derived(effortLevels(config.provider));

  function cleanProjectPath(raw: string): string {
    const trimmed = raw.trim();
    return trimmed.length > 1 ? trimmed.replace(/[\\/]+$/, "") : trimmed;
  }

  const favorites = $derived.by(() => {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const raw of settings?.favoriteProjects ?? []) {
      const path = cleanProjectPath(raw);
      if (!path || seen.has(path)) continue;
      seen.add(path);
      out.push(path);
    }
    return out;
  });

  const recent = $derived.by(() => {
    const seen = new Set<string>(favorites);
    const limit = Math.max(3, 10 - favorites.length);
    const out: string[] = [];
    for (const raw of [config.projectPath, settings?.lastProject ?? "", ...(settings?.recentProjects ?? []), ...(agents.history?.sessions ?? []).map((s) => s.cwd)]) {
      const path = cleanProjectPath(raw);
      if (!path || seen.has(path)) continue;
      seen.add(path);
      out.push(path);
      if (out.length === limit) break;
    }
    return out;
  });

  function toggleFavorite(path: string) {
    const clean = cleanProjectPath(path);
    if (!clean) return;
    workspaceApi.toggleFavoriteProject(clean).catch(() => {});
  }

  const worktreeAllowed = $derived(!!project && project.verdict === "ok" && !!project.repoRoot && project.hasCommits && !!workspace.overview?.gitAvailable);
  const worktreeBlocked = $derived(
    !workspace.overview?.gitAvailable ? tr("Git is niet gevonden. Installeer Git en start Nook opnieuw.", "Git wasn't found. Install Git and restart Nook.")
      : !project ? tr("Kies een project of map", "Choose a project or folder")
        : !project.repoRoot ? tr("Een worktree kan alleen in een Git-repository.", "A worktree only works in a Git repository.")
          : !project.hasCommits ? tr("Een worktree kan pas na de eerste commit.", "A worktree needs at least one commit.") : "",
  );
  const sharing = $derived(
    project && project.verdict === "ok"
      ? workspace.runs.filter((r) => isActive(r.status) && (r.workingDirectory === (project!.repoRoot ?? project!.path) || r.workingDirectory === project!.path))
      : [],
  );
  const blockingReason = $derived.by((): string | null => {
    if (!config.task.trim()) return tr("Schrijf eerst een opdracht.", "Write a task first.");
    if (!config.projectPath) return tr("Kies een map.", "Choose a folder.");
    if (!policies.includes(config.permission)) return tr("Deze agent ondersteunt die rechten niet.", "This agent doesn't support that permission.");
    if (config.isolation === "worktree" && !config.baseBranch) return tr("Kies een basis-branch.", "Choose a base branch.");
    if (project?.verdict !== "ok") return project?.verdictMessage || tr("Kies een map.", "Choose a folder.");
    if (!provider?.supported) return tr("Nook kan {agent} op dit platform nog niet zelf aansturen. Claude Code, Codex en Gemini CLI wel.", "Nook can't drive {agent} itself on this platform yet. Claude Code, Codex and Gemini CLI it can.", { agent: provider?.name ?? config.provider });
    if (!provider?.executable) return tr("{agent} staat niet op deze computer.", "{agent} isn't installed on this computer.", { agent: provider?.name ?? config.provider });
    if (config.isolation === "folder" && !allowShared && sharing.length) return tr("Kies een worktree of bevestig de gedeelde map.", "Choose a worktree or confirm the shared folder.");
    return null;
  });

  $effect(() => {
    if (prepared || !settings || !workspace.providers.length) return;
    prepared = true;
    prepare();
  });

  async function prepare() {
    profiles = await agentApi.profiles().catch(() => []);
    const list = connected.map((p) => p.provider);
    const p = list.includes(settings!.defaultProvider) ? settings!.defaultProvider : (list[0] ?? settings!.defaultProvider);
    choose(p, null);
    config.model = rememberedModel(p);
    config.effort = rememberedEffort(p);
    config.mode = settings!.defaultMode;
    config.isolation = settings!.defaultIsolation;
    config.worktreeRoot = settings!.worktreeRoot;
    requestAnimationFrame(() => textarea?.focus());
    const candidates = settings!.lastProject ? [settings!.lastProject] : [...favorites, ...recent];
    for (const path of candidates) {
      const result = await select(path);
      if (result === "stale") return;
      if (result === "ok") break;
    }
  }

  function choose(p: RunProvider, account: string | null) {
    if (config.provider !== p) {
      config.provider = p;
      config.model = rememberedModel(p);
      config.effort = rememberedEffort(p);
    }
    const caps = workspace.provider(p)?.capabilities.policies ?? ["acceptEdits"];
    if (!caps.includes(config.permission)) {
      const preferred = settings?.defaultPermission ?? "acceptEdits";
      config.permission = caps.includes(preferred) ? preferred : "acceptEdits";
    }
    const own = profilesFor(p);
    // The account you last chose for this agent in this folder or else anywhere, while it is still there, else its
    // preferred or first one.
    const remembered = [folderChoices(config.projectPath)?.agents[p]?.profileId, settings?.defaultProfiles?.[p]].find((saved) => saved && own.some((x) => x.id === saved));
    config.profileId = account ?? remembered ?? (own.find((x) => x.preferred) ?? own[0])?.id ?? p;
  }

  /// What you last chose in this folder, if anything.
  function folderChoices(path: string) {
    return settings?.folderChoices?.[cleanProjectPath(path)];
  }

  /// The model last chosen for this agent in this folder, else anywhere.
  function rememberedModel(p: RunProvider): string {
    return folderChoices(config.projectPath)?.agents[p]?.model ?? settings?.defaultModels[p] ?? "";
  }

  /// The effort last chosen for this agent in this folder, else anywhere, while the agent still offers it.
  function rememberedEffort(p: RunProvider): string | null {
    const chosen = folderChoices(config.projectPath)?.agents[p];
    const saved = chosen ? chosen.effort : settings?.defaultEfforts?.[p];
    return saved && effortLevels(p).includes(saved) ? saved : null;
  }

  /// Sets the choices to what a new session in the current folder starts with. Your agent for it, unless that is not
  /// connected: then your default one, or else the first that is.
  function applyFolderChoices() {
    if (!settings) return;
    const saved = folderChoices(config.projectPath);
    const list = connected.map((p) => p.provider);
    const p = [saved?.provider, settings.defaultProvider].find((x) => x && list.includes(x)) ?? list[0] ?? settings.defaultProvider;
    config.provider = p;
    config.mode = saved?.mode ?? settings.defaultMode;
    config.permission = saved?.permission ?? settings.defaultPermission;
    config.isolation = saved?.isolation ?? settings.defaultIsolation;
    config.model = rememberedModel(p);
    config.effort = rememberedEffort(p);
    choose(p, null);
  }

  /// Keeps what you just chose for the next new session in this folder, and as the start for folders without choices
  /// of their own.
  function remember() {
    if (!settings) return;
    const p = config.provider;
    const efforts = { ...(settings.defaultEfforts ?? {}) };
    if (config.effort) efforts[p] = config.effort;
    else delete efforts[p];
    const folder = cleanProjectPath(config.projectPath);
    const folders = { ...(settings.folderChoices ?? {}) };
    if (folder) {
      folders[folder] = {
        provider: p,
        mode: config.mode,
        permission: config.permission,
        isolation: config.isolation,
        agents: { ...(folders[folder]?.agents ?? {}), [p]: { profileId: config.profileId, model: config.model, effort: config.effort } },
      };
    }
    workspaceApi
      .saveSettings({
        ...$state.snapshot(settings),
        defaultProvider: p,
        defaultModels: { ...settings.defaultModels, [p]: config.model },
        defaultProfiles: { ...(settings.defaultProfiles ?? {}), [p]: config.profileId },
        defaultEfforts: efforts,
        defaultMode: config.mode,
        defaultPermission: config.permission,
        defaultIsolation: config.isolation,
        folderChoices: folders,
      })
      .catch(() => {});
  }

  async function select(path: string): Promise<"ok" | "failed" | "stale"> {
    const request = ++selectionRequest;
    menu = "";
    config.projectPath = path;
    inspecting = true;
    error = null;
    try {
      const info = await workspaceApi.inspect(path);
      if (request !== selectionRequest) return "stale";
      project = info;
      config.projectPath = info.path;
      const folder = cleanProjectPath(info.path);
      if (folder !== folderApplied) {
        folderApplied = folder;
        applyFolderChoices();
      }
      const canWorktree = !!info.repoRoot && info.hasCommits && !!workspace.overview?.gitAvailable;
      if (!canWorktree) config.isolation = "folder";
      else if (config.isolation === "folder" && (folderChoices(folder)?.isolation ?? settings?.defaultIsolation) === "worktree") config.isolation = "worktree";
      config.baseBranch = info.defaultBase && info.branches.includes(info.defaultBase) ? info.defaultBase : (info.currentBranch ?? info.branches[0] ?? "");
      return info.verdict === "ok" ? "ok" : "failed";
    } catch (e) {
      if (request !== selectionRequest) return "stale";
      error = String(e);
      return "failed";
    } finally {
      if (request === selectionRequest) inspecting = false;
    }
  }

  async function chooseFolder() {
    menu = "";
    try {
      const picked = await openDialog({ directory: true, multiple: false, title: tr("In welke map werkt de agent?", "Which folder does the agent work in?"), defaultPath: project?.path });
      if (typeof picked === "string") select(picked);
    } catch (e) {
      error = String(e);
    }
  }

  async function clone() {
    if (cloning || !cloneUrl.trim()) return;
    cloning = true;
    error = null;
    try {
      const path = await workspaceApi.clone(cloneUrl.trim(), project?.repoRoot ?? project?.path ?? null);
      showClone = false;
      cloneUrl = "";
      select(path);
    } catch (e) {
      error = String(e);
    }
    cloning = false;
  }

  async function start() {
    if (starting || blockingReason) return;
    starting = true;
    error = null;
    try {
      const id = await workspaceApi.start({ ...config, branchName: "" }, allowShared);
      config.task = "";
      await workspace.refresh();
      onstarted(id);
    } catch (e) {
      error = String(e);
    }
    starting = false;
  }

  function sortedBranches(list: string[]): string[] {
    const base = project?.defaultBase;
    const q = branchQuery.trim().toLowerCase();
    return [...list].filter((b) => !q || b.toLowerCase().includes(q)).sort((a, b) => (a === base ? -1 : b === base ? 1 : a.localeCompare(b, undefined, { numeric: true })));
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      start();
    }
  }

  const stop = (e: Event) => e.stopPropagation();
</script>

<svelte:window onclick={() => (menu = "")} />

<div class="new">
  <div class="spacer-v"></div>
  <h2 class="heading">
    {tr("Wat zullen we bouwen in", "What shall we build in")}
    <span class="pop">
      <button class="project" onclick={(e) => { stop(e); menu = menu === "project" ? "" : "project"; }} title={project?.path ?? tr("Kies een project of map", "Choose a project or folder")}>
        {project?.name ?? (config.projectPath ? projectName(config.projectPath) : tr("welke map", "which folder"))}
      </button>
      {#if menu === "project"}
        <div class="menu" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
          {#if favorites.length}
            <div class="mhead">{tr("Favorieten", "Favorites")}</div>
            {#each favorites as path (path)}
              <div class="mrow" class:chosen={cleanProjectPath(project?.path ?? "") === path}>
                <button class="mitem" onclick={() => select(path)}><span>{projectName(path)}</span><span class="faint small">{path}</span></button>
                <button class="star starred" title={tr("Verwijder uit favorieten", "Remove from favorites")} aria-label={tr("Verwijder uit favorieten", "Remove from favorites")} onclick={() => toggleFavorite(path)}>★</button>
              </div>
            {/each}
          {/if}
          {#if recent.length}
            <div class="mhead">{tr("Recent", "Recent")}</div>
            {#each recent as path (path)}
              <div class="mrow" class:chosen={cleanProjectPath(project?.path ?? "") === path}>
                <button class="mitem" onclick={() => select(path)}><span>{projectName(path)}</span><span class="faint small">{path}</span></button>
                <button class="star" title={tr("Voeg toe aan favorieten", "Add to favorites")} aria-label={tr("Voeg toe aan favorieten", "Add to favorites")} onclick={() => toggleFavorite(path)}>☆</button>
              </div>
            {/each}
          {/if}
          {#if favorites.length || recent.length}
            <hr />
          {/if}
          <button onclick={chooseFolder}>{tr("Kies map…", "Choose folder…")}</button>
          <button onclick={() => { menu = ""; showClone = true; }}>{tr("Kloon een repository…", "Clone a repository…")}</button>
        </div>
      {/if}
    </span>?
    {#if inspecting}<span class="faint small">{tr("Map bekijken…", "Checking folder…")}</span>{/if}
  </h2>

  {#if showClone}
    <div class="clone">
      <input bind:value={cloneUrl} placeholder={tr("https://github.com/eigenaar/repo.git", "https://github.com/owner/repo.git")} onkeydown={(e) => e.key === "Enter" && clone()} />
      <button disabled={cloning || !cloneUrl.trim()} onclick={clone}>{cloning ? tr("Klonen…", "Cloning…") : tr("Kloon", "Clone")}</button>
      <button class="ghost" onclick={() => (showClone = false)}>✕</button>
    </div>
  {/if}

  <div class="box">
    <textarea bind:this={textarea} bind:value={config.task} rows="3" placeholder={tr("Beschrijf wat de agent moet doen. Enter start de sessie.", "Describe what the agent should do. Enter starts the session.")} onkeydown={keydown}></textarea>
    <div class="bar">
      <span class="pop">
        <button class="pill" onclick={(e) => { stop(e); menu = menu === "agent" ? "" : "agent"; }} title={tr("Deze sessie houdt dit account, ook als je later het standaardaccount wisselt.", "This session keeps this account, even if you switch the default account later.")}>
          {provider?.name ?? config.provider}{profile && profilesFor(config.provider).length > 1 ? " · " + (profile.label || tr("Standaard", "Default")) : ""}{config.model ? ` · ${config.model}` : ""}
        </button>
        {#if menu === "agent"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            {#if !connected.length}
              <div class="mhead">{tr("Nog geen agent gekoppeld. Koppel er een bij Instellingen › Agents.", "No agent linked yet. Link one in Settings › Agents.")}</div>
            {/if}
            {#each runnable as p (p.provider)}
              <div class="mhead">{p.name}{#if !p.executable} · {tr("niet gevonden", "not found")}{/if}</div>
              {#each profilesFor(p.provider).length ? profilesFor(p.provider) : [{ id: p.provider, label: "", title: p.name } as AgentProfile] as acc (acc.id)}
                <button class:chosen={config.provider === p.provider && config.profileId === acc.id} disabled={!p.executable}
                  onclick={() => { choose(p.provider, acc.id); menu = ""; remember(); }}>{acc.label || tr("Standaardaccount", "Default account")}</button>
              {/each}
            {/each}
            <hr />
            <div class="mhead">{tr("Model", "Model")}</div>
            <input bind:value={config.model} placeholder={tr("standaard", "default")} onchange={remember} />
          </div>
        {/if}
      </span>
      <span class="sep"></span>
      <button class="pill" title={config.mode === "plan" ? tr("Alleen lezen en een plan maken; er wordt niets aangepast.", "Only read and make a plan; nothing is changed.") : tr("De agent mag werken in de map, binnen de rechten hieronder.", "The agent may work in the folder, within the permissions below.")}
        onclick={() => { config.mode = config.mode === "plan" ? "agent" : "plan"; remember(); }}>{config.mode === "plan" ? tr("Plan", "Plan") : tr("Agent", "Agent")}</button>
      <span class="sep"></span>
      <span class="pop">
        <button class="pill" class:hot={config.permission === "bypass" && config.mode !== "plan"} disabled={config.mode === "plan"}
          title={config.mode === "plan" ? tr("In Plan-modus leest de agent alleen.", "In Plan mode the agent only reads.") : permissionHelp(config.permission, config.provider)}
          onclick={(e) => { stop(e); menu = menu === "permission" ? "" : "permission"; }}>
          {config.mode === "plan" ? tr("Alleen lezen", "Read only") : permissionLabels[config.permission]}
        </button>
        {#if menu === "permission"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            <div class="mhead">{tr("Toegang", "Access")}</div>
            {#each policies as p (p)}
              <button class="opt" class:chosen={config.permission === p} onclick={() => { config.permission = p; menu = ""; remember(); }}>
                <span class:hot={p === "bypass"}>{permissionLabels[p]}</span><span class="faint small">{permissionHelp(p, config.provider)}</span>
              </button>
            {/each}
          </div>
        {/if}
      </span>
      {#if levels.length}
        <span class="sep"></span>
        <span class="pop">
          <button class="pill" title={tr("Hoe diep de agent nadenkt, vanaf de volgende beurt", "How deeply the agent thinks, from the next turn")} onclick={(e) => { stop(e); menu = menu === "effort" ? "" : "effort"; }}>
            {effortLabels[config.effort ?? ""] ?? config.effort}
          </button>
          {#if menu === "effort"}
            <div class="menu" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
              <div class="mhead">{tr("Denkniveau", "Effort")}</div>
              <button class:chosen={!config.effort} onclick={() => { config.effort = null; menu = ""; remember(); }}>{effortLabels[""]}</button>
              {#each levels as l (l)}
                <button class:chosen={config.effort === l} onclick={() => { config.effort = l; menu = ""; remember(); }}>{effortLabels[l] ?? l}</button>
              {/each}
            </div>
          {/if}
        </span>
      {/if}
      <span class="spacer"></span>
      <button class="primary" disabled={!!blockingReason || starting} title={blockingReason ?? tr("Start sessie", "Start session")} onclick={start}>{starting ? (config.isolation === "worktree" ? tr("Worktree maken en agent starten…", "Creating worktree and starting agent…") : tr("Agent starten…", "Starting agent…")) : tr("Start sessie", "Start session")}</button>
    </div>
  </div>

  <div class="below">
    <span class="pop">
      <button class="pill" title={worktreeAllowed ? tr("De agent krijgt een eigen map en branch. Je eigen checkout en branch blijven precies zoals ze zijn.", "The agent gets its own folder and branch. Your own checkout and branch stay exactly as they are.") : worktreeBlocked}
        onclick={(e) => { stop(e); menu = menu === "where" ? "" : "where"; }}>{config.isolation === "worktree" ? tr("Nieuwe worktree", "New worktree") : tr("Huidige map", "Current folder")}</button>
      {#if menu === "where"}
        <div class="menu wide" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
          <div class="mhead">{tr("Waar de agent werkt", "Where the agent works")}</div>
          <button class="opt" class:chosen={config.isolation === "folder"} onclick={() => { config.isolation = "folder"; menu = ""; remember(); }}>
            <span>{tr("Huidige map", "Current folder")}</span><span class="faint small">{tr("In de map zelf, op de branch die er nu staat.", "In the folder itself, on the branch that's checked out now.")}</span>
          </button>
          <button class="opt" class:chosen={config.isolation === "worktree"} disabled={!worktreeAllowed} onclick={() => { config.isolation = "worktree"; menu = ""; remember(); }}>
            <span>{tr("Nieuwe worktree", "New worktree")}</span><span class="faint small">{worktreeAllowed ? tr("De agent krijgt een eigen map en branch. Je eigen checkout en branch blijven precies zoals ze zijn.", "The agent gets its own folder and branch. Your own checkout and branch stay exactly as they are.") : worktreeBlocked}</span>
          </button>
        </div>
      {/if}
    </span>
    <span class="spacer"></span>
    {#if config.isolation === "worktree" && project?.branches.length}
      <span class="pop">
        <button class="pill" onclick={(e) => { stop(e); branchQuery = ""; menu = menu === "branch" ? "" : "branch"; }}>⑂ {tr("Vanaf {branch}", "From {branch}", { branch: config.baseBranch })}</button>
        {#if menu === "branch"}
          <div class="menu wide right" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            <input bind:value={branchQuery} placeholder={tr("Zoek branches…", "Search branches…")} />
            <div class="scrolllist">
              {#each sortedBranches(project.branches) as b (b)}
                <button class:chosen={config.baseBranch === b} onclick={() => { config.baseBranch = b; menu = ""; }}>{b}</button>
              {:else}
                <span class="faint small">{tr("Geen branches gevonden", "No branches found")}</span>
              {/each}
            </div>
          </div>
        {/if}
      </span>
    {:else if project?.currentBranch}
      <span class="pill static">⑂ {project.currentBranch}</span>
    {/if}
  </div>

  {#if error}
    <p class="err">{error}</p>
  {:else if sharing.length && config.isolation === "folder"}
    <p class="note">
      {tr("Er werkt al een sessie in deze map: {sessions}. Twee agents in dezelfde map kunnen elkaars werk overschrijven.", "A session is already working in this folder: {sessions}. Two agents in the same folder can overwrite each other's work.", { sessions: sharing.map((r) => r.title).join(", ") })}
      <label><input type="checkbox" bind:checked={allowShared} /> {tr("Ik weet het, start toch in dezelfde map", "I know, start in the same folder anyway")}</label>
    </p>
  {:else if project && project.verdict !== "ok"}
    <p class="err">{project.verdictMessage}</p>
  {:else if blockingReason && project && config.task}
    <p class="faint small">{blockingReason}</p>
  {:else if project && !project.repoRoot}
    <p class="faint small">{tr("Geen Git-repository: de agent werkt in de map zelf.", "No Git repository: the agent works in the folder itself.")}</p>
  {:else if config.isolation === "worktree" && project?.dirtyFiles}
    <p class="faint small">{tr("Je hebt {n} niet-gecommitte wijzigingen. Die gaan niet mee naar de nieuwe worktree; hij begint vanaf de basis-branch.", "You have {n} uncommitted changes. They don't move to the new worktree; it starts from the base branch.", { n: project.dirtyFiles })}</p>
  {/if}
  <div class="spacer-v"></div>
</div>

<style>
  .new { display: flex; flex-direction: column; gap: 10px; height: 100%; max-width: 720px; margin: 0 auto; width: 100%; }
  .spacer-v { flex: 1; }
  .heading { font-size: 20px; font-weight: 600; margin: 0 0 8px; text-align: center; display: flex; gap: 6px; justify-content: center; align-items: baseline; flex-wrap: wrap; }
  .project { background: none; border: none; padding: 0; font: inherit; color: var(--paper); text-decoration: underline dotted var(--text3); text-underline-offset: 4px; }
  .project:hover { background: none; }
  .clone { display: flex; gap: 6px; }
  .clone input { flex: 1; }
  .box { border: 1px solid var(--line2); border-radius: 14px; background: var(--field); padding: 10px; display: flex; flex-direction: column; gap: 6px; }
  textarea { background: transparent; border: none; resize: none; min-height: 56px; }
  textarea:focus { border: none; }
  .bar, .below { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
  .pill { background: none; border: none; padding: 3px 8px; font-size: 12.5px; color: var(--text2); border-radius: 8px; }
  .pill:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  .pill.static:hover { background: none; color: var(--text2); }
  .hot { color: #ff9b9b; }
  .sep { width: 1px; height: 16px; background: #3a3a44; margin: 0 3px; }
  .spacer { flex: 1; }
  .pop { position: relative; display: inline-block; }
  .menu { position: absolute; top: 30px; left: 0; z-index: 20; background: var(--graphite); border: 1px solid var(--line2); border-radius: 10px; padding: 4px; display: flex; flex-direction: column; min-width: 220px; box-shadow: 0 8px 30px rgba(0, 0, 0, 0.5); font-size: 12.5px; font-weight: 400; text-align: left; }
  .menu.wide { width: 320px; gap: 2px; padding: 8px; }
  .menu.right { left: auto; right: 0; }
  .menu button { background: none; border: none; text-align: left; padding: 6px 8px; border-radius: 7px; display: flex; flex-direction: column; gap: 1px; font-size: 12.5px; }
  .menu button:hover:not(:disabled), .menu button.chosen { background: var(--smoke); }
  .mrow { display: flex; align-items: center; border-radius: 7px; }
  .mrow:hover, .mrow.chosen { background: var(--smoke); }
  .mrow .mitem { flex: 1; min-width: 0; }
  .mrow .mitem:hover { background: none; }
  .mrow .star { opacity: 0; padding: 4px 8px; color: var(--text3); font-size: 13px; align-items: center; justify-content: center; }
  .mrow:hover .star, .mrow .star:focus-visible, .mrow .star.starred { opacity: 1; }
  .mrow .star.starred, .mrow .star:focus-visible { color: var(--paper); }
  .mrow .star:hover { background: none; color: var(--paper); }
  .menu hr { border: none; border-top: 1px solid var(--line2); margin: 4px 0; width: 100%; }
  .mhead { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 4px; }
  .scrolllist { max-height: 240px; overflow-y: auto; display: flex; flex-direction: column; }
  .small { font-size: 11.5px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  .note { font-size: 12px; color: var(--amber); margin: 0; display: flex; flex-direction: column; gap: 4px; }
</style>
