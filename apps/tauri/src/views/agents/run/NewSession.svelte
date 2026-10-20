<script lang="ts">
  // Een sessie starten (`NewSessionComposer` op de Mac): één vraag, één veld en een paar rustige keuzes eronder.
  // "Wat zullen we bouwen in nook?" — typ de opdracht, druk op Enter. Agent en account, model, modus, rechten, denkniveau, waar hij
  // werkt (deze map of een nieuwe worktree) en de branch waar hij van start staan al op je laatste keuzes. Titel,
  // branchnaam en de plek van de worktree volgen vanzelf.
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agentApi, type AgentProfile } from "../../../lib/agents";
  import { agents } from "../../../lib/agents.svelte";
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
  let prepared = false;

  const settings = $derived(workspace.settings);
  const runnable = $derived(workspace.providers.filter((p) => p.supported));
  const connected = $derived(runnable.filter((p) => p.executable));
  const provider = $derived(workspace.provider(config.provider));
  const policies = $derived<PermissionPolicy[]>(provider?.capabilities.policies ?? ["acceptEdits"]);
  const profilesFor = (p: RunProvider) => profiles.filter((x) => x.kind === p);
  const profile = $derived(profiles.find((p) => p.id === config.profileId));
  const levels = $derived(effortLevels(config.provider));

  const recent = $derived.by(() => {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const path of [...(settings?.recentProjects ?? []), ...(agents.history?.sessions ?? []).map((s) => s.cwd)]) {
      if (!path || seen.has(path)) continue;
      seen.add(path);
      out.push(path);
      if (out.length === 10) break;
    }
    return out;
  });

  const worktreeAllowed = $derived(!!project && project.verdict === "ok" && !!project.repoRoot && project.hasCommits && !!workspace.overview?.gitAvailable);
  const worktreeBlocked = $derived(
    !workspace.overview?.gitAvailable ? "Git is niet gevonden. Installeer Git en start Nook opnieuw."
      : !project ? "Kies een project of map"
        : !project.repoRoot ? "Een worktree kan alleen in een Git-repository."
          : !project.hasCommits ? "Een worktree kan pas na de eerste commit." : "",
  );
  const sharing = $derived(
    project && project.verdict === "ok"
      ? workspace.runs.filter((r) => isActive(r.status) && (r.workingDirectory === (project!.repoRoot ?? project!.path) || r.workingDirectory === project!.path))
      : [],
  );
  const blockingReason = $derived.by((): string | null => {
    if (!config.task.trim()) return "Schrijf eerst een opdracht.";
    if (!config.projectPath) return "Kies een map.";
    if (!policies.includes(config.permission)) return "Deze agent ondersteunt die rechten niet.";
    if (config.isolation === "worktree" && !config.baseBranch) return "Kies een basis-branch.";
    if (project?.verdict !== "ok") return project?.verdictMessage || "Kies een map.";
    if (!provider?.supported) return `Nook kan ${provider?.name ?? config.provider} op dit platform nog niet zelf aansturen. Claude Code, Codex en Gemini CLI wel.`;
    if (!provider?.executable) return `${provider?.name ?? config.provider} staat niet op deze computer.`;
    if (config.isolation === "folder" && !allowShared && sharing.length) return "Kies een worktree of bevestig de gedeelde map.";
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
    config.model = settings!.defaultModels[p] ?? "";
    config.effort = rememberedEffort(p);
    config.mode = settings!.defaultMode;
    config.isolation = settings!.defaultIsolation;
    config.worktreeRoot = settings!.worktreeRoot;
    requestAnimationFrame(() => textarea?.focus());
    const initial = settings!.lastProject || recent[0];
    if (initial) select(initial);
  }

  function choose(p: RunProvider, account: string | null) {
    if (config.provider !== p) {
      config.provider = p;
      config.model = settings?.defaultModels[p] ?? "";
      config.effort = rememberedEffort(p);
    }
    const caps = workspace.provider(p)?.capabilities.policies ?? ["acceptEdits"];
    if (!caps.includes(config.permission)) {
      const preferred = settings?.defaultPermission ?? "acceptEdits";
      config.permission = caps.includes(preferred) ? preferred : "acceptEdits";
    }
    const own = profilesFor(p);
    // The account you last chose for this agent while it is still there, else its preferred or first one.
    const saved = settings?.defaultProfiles?.[p];
    const remembered = saved && own.some((x) => x.id === saved) ? saved : null;
    config.profileId = account ?? remembered ?? (own.find((x) => x.preferred) ?? own[0])?.id ?? p;
  }

  /// The effort last chosen for this agent, while the agent still offers it.
  function rememberedEffort(p: RunProvider): string | null {
    const saved = settings?.defaultEfforts?.[p];
    return saved && effortLevels(p).includes(saved) ? saved : null;
  }

  /// Keeps what you just chose for the next new session, so it does not fall back to the defaults.
  function remember() {
    if (!settings) return;
    const p = config.provider;
    const efforts = { ...(settings.defaultEfforts ?? {}) };
    if (config.effort) efforts[p] = config.effort;
    else delete efforts[p];
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
      })
      .catch(() => {});
  }

  async function select(path: string) {
    menu = "";
    config.projectPath = path;
    inspecting = true;
    error = null;
    try {
      const info = await workspaceApi.inspect(path);
      project = info;
      config.projectPath = info.path;
      const canWorktree = !!info.repoRoot && info.hasCommits && !!workspace.overview?.gitAvailable;
      if (!canWorktree) config.isolation = "folder";
      else if (config.isolation === "folder" && settings?.defaultIsolation === "worktree") config.isolation = "worktree";
      config.baseBranch = info.defaultBase && info.branches.includes(info.defaultBase) ? info.defaultBase : (info.currentBranch ?? info.branches[0] ?? "");
    } catch (e) {
      error = String(e);
    }
    inspecting = false;
  }

  async function chooseFolder() {
    menu = "";
    try {
      const picked = await openDialog({ directory: true, multiple: false, title: "In welke map werkt de agent?", defaultPath: project?.path });
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
    Wat zullen we bouwen in
    <span class="pop">
      <button class="project" onclick={(e) => { stop(e); menu = menu === "project" ? "" : "project"; }} title={project?.path ?? "Kies een project of map"}>
        {project?.name ?? (config.projectPath ? projectName(config.projectPath) : "welke map")}
      </button>
      {#if menu === "project"}
        <div class="menu" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
          {#if recent.length}
            <div class="mhead">Recent</div>
            {#each recent as path (path)}
              <button class:chosen={project?.path === path} onclick={() => select(path)}><span>{projectName(path)}</span><span class="faint small">{path}</span></button>
            {/each}
            <hr />
          {/if}
          <button onclick={chooseFolder}>Kies map…</button>
          <button onclick={() => { menu = ""; showClone = true; }}>Kloon een repository…</button>
        </div>
      {/if}
    </span>?
    {#if inspecting}<span class="faint small">Map bekijken…</span>{/if}
  </h2>

  {#if showClone}
    <div class="clone">
      <input bind:value={cloneUrl} placeholder="https://github.com/eigenaar/repo.git" onkeydown={(e) => e.key === "Enter" && clone()} />
      <button disabled={cloning || !cloneUrl.trim()} onclick={clone}>{cloning ? "Klonen…" : "Kloon"}</button>
      <button class="ghost" onclick={() => (showClone = false)}>✕</button>
    </div>
  {/if}

  <div class="box">
    <textarea bind:this={textarea} bind:value={config.task} rows="3" placeholder="Beschrijf wat de agent moet doen. Enter start de sessie." onkeydown={keydown}></textarea>
    <div class="bar">
      <span class="pop">
        <button class="pill" onclick={(e) => { stop(e); menu = menu === "agent" ? "" : "agent"; }} title="Deze sessie houdt dit account, ook als je later het standaardaccount wisselt.">
          {provider?.name ?? config.provider}{profile && profilesFor(config.provider).length > 1 ? ` · ${profile.label || "Standaard"}` : ""}{config.model ? ` · ${config.model}` : ""}
        </button>
        {#if menu === "agent"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            {#if !connected.length}
              <div class="mhead">Nog geen agent gekoppeld. Koppel er een bij Instellingen › Agents.</div>
            {/if}
            {#each runnable as p (p.provider)}
              <div class="mhead">{p.name}{#if !p.executable} · niet gevonden{/if}</div>
              {#each profilesFor(p.provider).length ? profilesFor(p.provider) : [{ id: p.provider, label: "", title: p.name } as AgentProfile] as acc (acc.id)}
                <button class:chosen={config.provider === p.provider && config.profileId === acc.id} disabled={!p.executable}
                  onclick={() => { choose(p.provider, acc.id); menu = ""; remember(); }}>{acc.label || "Standaardaccount"}</button>
              {/each}
            {/each}
            <hr />
            <div class="mhead">Model</div>
            <input bind:value={config.model} placeholder="standaard" onchange={remember} />
          </div>
        {/if}
      </span>
      <span class="sep"></span>
      <button class="pill" title={config.mode === "plan" ? "Alleen lezen en een plan maken; er wordt niets aangepast." : "De agent mag werken in de map, binnen de rechten hieronder."}
        onclick={() => { config.mode = config.mode === "plan" ? "agent" : "plan"; remember(); }}>{config.mode === "plan" ? "Plan" : "Agent"}</button>
      <span class="sep"></span>
      <span class="pop">
        <button class="pill" class:hot={config.permission === "bypass" && config.mode !== "plan"} disabled={config.mode === "plan"}
          title={config.mode === "plan" ? "In Plan-modus leest de agent alleen." : permissionHelp(config.permission, config.provider)}
          onclick={(e) => { stop(e); menu = menu === "permission" ? "" : "permission"; }}>
          {config.mode === "plan" ? "Alleen lezen" : permissionLabels[config.permission]}
        </button>
        {#if menu === "permission"}
          <div class="menu wide" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            <div class="mhead">Toegang</div>
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
          <button class="pill" title="Hoe diep de agent nadenkt, vanaf de volgende beurt" onclick={(e) => { stop(e); menu = menu === "effort" ? "" : "effort"; }}>
            {effortLabels[config.effort ?? ""] ?? config.effort}
          </button>
          {#if menu === "effort"}
            <div class="menu" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
              <div class="mhead">Denkniveau</div>
              <button class:chosen={!config.effort} onclick={() => { config.effort = null; menu = ""; remember(); }}>{effortLabels[""]}</button>
              {#each levels as l (l)}
                <button class:chosen={config.effort === l} onclick={() => { config.effort = l; menu = ""; remember(); }}>{effortLabels[l] ?? l}</button>
              {/each}
            </div>
          {/if}
        </span>
      {/if}
      <span class="spacer"></span>
      <button class="primary" disabled={!!blockingReason || starting} title={blockingReason ?? "Start sessie"} onclick={start}>{starting ? (config.isolation === "worktree" ? "Worktree maken en agent starten…" : "Agent starten…") : "Start sessie"}</button>
    </div>
  </div>

  <div class="below">
    <span class="pop">
      <button class="pill" title={worktreeAllowed ? "De agent krijgt een eigen map en branch. Je eigen checkout en branch blijven precies zoals ze zijn." : worktreeBlocked}
        onclick={(e) => { stop(e); menu = menu === "where" ? "" : "where"; }}>{config.isolation === "worktree" ? "Nieuwe worktree" : "Huidige map"}</button>
      {#if menu === "where"}
        <div class="menu wide" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
          <div class="mhead">Waar de agent werkt</div>
          <button class="opt" class:chosen={config.isolation === "folder"} onclick={() => { config.isolation = "folder"; menu = ""; remember(); }}>
            <span>Huidige map</span><span class="faint small">In de map zelf, op de branch die er nu staat.</span>
          </button>
          <button class="opt" class:chosen={config.isolation === "worktree"} disabled={!worktreeAllowed} onclick={() => { config.isolation = "worktree"; menu = ""; remember(); }}>
            <span>Nieuwe worktree</span><span class="faint small">{worktreeAllowed ? "De agent krijgt een eigen map en branch. Je eigen checkout en branch blijven precies zoals ze zijn." : worktreeBlocked}</span>
          </button>
        </div>
      {/if}
    </span>
    <span class="spacer"></span>
    {#if config.isolation === "worktree" && project?.branches.length}
      <span class="pop">
        <button class="pill" onclick={(e) => { stop(e); branchQuery = ""; menu = menu === "branch" ? "" : "branch"; }}>⑂ Vanaf {config.baseBranch}</button>
        {#if menu === "branch"}
          <div class="menu wide right" role="menu" tabindex="-1" onclick={stop} onkeydown={() => {}}>
            <input bind:value={branchQuery} placeholder="Zoek branches…" />
            <div class="scrolllist">
              {#each sortedBranches(project.branches) as b (b)}
                <button class:chosen={config.baseBranch === b} onclick={() => { config.baseBranch = b; menu = ""; }}>{b}</button>
              {:else}
                <span class="faint small">Geen branches gevonden</span>
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
      Er werkt al een sessie in deze map: {sharing.map((r) => r.title).join(", ")}. Twee agents in dezelfde map kunnen elkaars werk overschrijven.
      <label><input type="checkbox" bind:checked={allowShared} /> Ik weet het, start toch in dezelfde map</label>
    </p>
  {:else if project && project.verdict !== "ok"}
    <p class="err">{project.verdictMessage}</p>
  {:else if blockingReason && project && config.task}
    <p class="faint small">{blockingReason}</p>
  {:else if project && !project.repoRoot}
    <p class="faint small">Geen Git-repository: de agent werkt in de map zelf.</p>
  {:else if config.isolation === "worktree" && project?.dirtyFiles}
    <p class="faint small">Je hebt {project.dirtyFiles} niet-gecommitte wijzigingen. Die gaan niet mee naar de nieuwe worktree; hij begint vanaf de basis-branch.</p>
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
  .menu hr { border: none; border-top: 1px solid var(--line2); margin: 4px 0; width: 100%; }
  .mhead { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 4px; }
  .scrolllist { max-height: 240px; overflow-y: auto; display: flex; flex-direction: column; }
  .small { font-size: 11.5px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  .note { font-size: 12px; color: var(--amber); margin: 0; display: flex; flex-direction: column; gap: 4px; }
</style>
