<script lang="ts">
  // Settings › Coding agents (`AgentsSettingsSection` + `SkillsSettingsSection` on the Mac):
  // Top segmented tab bar (Agents | Skills).
  // - Agents: list-and-detail layout covering every coding agent (installed status, version & update check, CLI path,
  //   install/update command, Antigravity ACP server setup, default model, Nook hook linking with diff preview, and
  //   extra accounts for Claude Code & Codex).
  // - Skills: global & per-project discovered skills across agents, scope/agent filters, inline SKILL.md preview with
  //   script inspection, non-destructive enable/disable toggle, and direct folder opening.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { ask } from "../../lib/confirm.svelte";
  import {
    agentApi,
    agentNames,
    type AgentKind,
    type AgentProfile,
    type Integration,
    type LinkPreview,
  } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { nook } from "../../lib/state.svelte";
  import { workspaceApi, type RunProvider, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import DiffView from "../agents/DiffView.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";

  type TopTab = "agents" | "skills";

  interface AgentVersionInfo {
    provider: RunProvider;
    executable: string | null;
    version: string | null;
    installCommand: string;
  }

  interface SkillCatalogEntry {
    name: string;
    description: string;
    path: string;
    folder: string;
    source: string;
    scope: "user" | "project";
    providers: RunProvider[];
    enabled: boolean;
  }

  interface SkillFolderInfo {
    path: string;
    label: string;
    scope: "user" | "project";
    exists: boolean;
    count: number;
  }

  interface SkillsCatalogView {
    skills: SkillCatalogEntry[];
    folders: SkillFolderInfo[];
  }

  interface SkillDocument {
    path: string;
    name: string;
    description: string;
    content: string;
    scripts: string[];
  }

  interface AntigravitySetup {
    supported: boolean;
    installed: boolean;
    busy: boolean;
    version: string;
    downloadBytes: number;
  }

  interface AntigravityProgress {
    phase: "downloading" | "verifying" | "unpacking" | "checking" | "done" | "failed";
    fraction: number;
    error?: string | null;
  }

  interface AgentEntry {
    id: string;
    name: string;
    provider: RunProvider | null;
    agentKind: AgentKind | null;
    integrations: Integration[];
    extraIntegrations: Integration[];
  }

  const RUNNABLE_ORDER: RunProvider[] = ["claude", "codex", "gemini", "antigravity", "opencode", "cursor", "grok"];

  let tab = $state<TopTab>("agents");
  let selectedId = $state<string>("claude");

  let integrations = $state<Integration[]>([]);
  let profiles = $state<AgentProfile[]>([]);
  let versions = $state<Record<string, AgentVersionInfo>>({});
  let checkingVersions = $state(false);
  let wsSettings = $state<WorkspaceSettings | null>(null);

  let pending = $state<LinkPreview | null>(null);
  let status = $state<string | null>(null);
  let error = $state<string | null>(null);
  let copiedPath = $state(false);
  let newLabel = $state<Record<string, string>>({});
  let keyInput = $state<Record<string, string>>({});

  // Antigravity ACP server setup state.
  let agSetup = $state<AntigravitySetup | null>(null);
  let agProgress = $state<AntigravityProgress | null>(null);

  // Skills tab state.
  let skillProject = $state<string>("");
  let skillAgents = $state<RunProvider[]>([]);
  let skillQuery = $state("");
  let skillsCatalog = $state<SkillsCatalogView | null>(null);
  let skillsLoading = $state(false);
  let previewPath = $state<string | null>(null);
  let previewDoc = $state<SkillDocument | null>(null);
  let previewLoading = $state(false);
  let previewError = $state<string | null>(null);

  const local = $derived(nook.info?.capabilities.localAgents ?? false);

  async function loadVersions() {
    checkingVersions = true;
    try {
      versions = await invoke<Record<string, AgentVersionInfo>>("workspace_agent_versions");
    } catch {
      // Command may not be wired yet in older builds.
    } finally {
      checkingVersions = false;
    }
  }

  async function loadAntigravity() {
    agSetup = await invoke<AntigravitySetup>("antigravity_setup").catch(() => null);
  }

  async function load() {
    if (!local) return;
    const [ints, profs] = await Promise.all([agentApi.integrations(), agentApi.profiles()]);
    integrations = ints;
    profiles = profs;
    agents.loadHistory();
    workspace.start().then(() => {
      wsSettings = workspace.settings ? { ...workspace.settings, defaultModels: { ...workspace.settings.defaultModels } } : null;
    });
    loadVersions();
    loadAntigravity();
  }

  async function loadSkills() {
    if (!local) return;
    skillsLoading = true;
    try {
      skillsCatalog = await invoke<SkillsCatalogView>("workspace_skills_catalog", {
        project: skillProject || null,
        providers: skillAgents.length > 0 ? skillAgents : null,
      });
    } catch (e) {
      error = String(e);
    } finally {
      skillsLoading = false;
    }
  }

  $effect(() => {
    load();
    const off = listen<AntigravityProgress>("antigravity-install", (e) => {
      agProgress = e.payload;
      if (e.payload.phase === "done" || e.payload.phase === "failed") {
        loadAntigravity();
        loadVersions();
        workspace.refresh();
      }
    });
    return () => {
      off.then((f) => f());
    };
  });

  $effect(() => {
    if (tab === "skills" && local) {
      // Re-run whenever scope or agent filter changes.
      const _p = skillProject;
      const _a = skillAgents.join(",");
      void _p;
      void _a;
      loadSkills();
    }
  });

  const agentEntries = $derived.by<AgentEntry[]>(() => {
    const entries: AgentEntry[] = [];
    const claimedTargets = new Set<string>();

    for (const provider of RUNNABLE_ORDER) {
      const kind = provider as AgentKind;
      const info = workspace.provider(provider);
      const name = info?.name ?? agentNames[kind] ?? provider;
      const own = integrations.filter((i) => !i.profileId && i.agent === kind);
      const extra = integrations.filter((i) => !!i.profileId && i.agent === kind);
      for (const i of own) claimedTargets.add(i.target);
      entries.push({
        id: provider,
        name,
        provider,
        agentKind: kind,
        integrations: own,
        extraIntegrations: extra,
      });
    }

    // Followed-only agents (Copilot CLI, Muse Code, Amp, Hermes, etc.) from integrations without a runnable provider.
    for (const i of integrations) {
      if (i.profileId || claimedTargets.has(i.target)) continue;
      entries.push({
        id: `follow:${i.target}`,
        name: i.title,
        provider: null,
        agentKind: i.agent,
        integrations: [i],
        extraIntegrations: [],
      });
    }

    return entries;
  });

  const selectedEntry = $derived(agentEntries.find((e) => e.id === selectedId) ?? agentEntries[0] ?? null);

  function linkWord(i: Integration): string {
    switch (i.state.kind) {
      case "installed":
        return tr("Gekoppeld", "Linked");
      case "outdated":
        return tr("Verouderd", "Outdated");
      case "unreadable":
        return tr("Instellingen niet leesbaar", "Can't read its settings");
      default:
        return tr("Niet gekoppeld", "Not linked");
    }
  }

  function stateText(i: Integration): string {
    switch (i.state.kind) {
      case "installed":
        return tr("klaar · {path}", "ready · {path}", { path: i.path });
      case "outdated":
        return tr(
          "Gekoppeld met een oudere versie: werk bij voor toestemming en vragen in de balk",
          "Linked with an older version: update for permissions and questions in the bar",
        );
      case "unreadable":
        return i.state.detail;
      default:
        return i.detail;
    }
  }

  function entryStanding(entry: AgentEntry): { tone: "installed" | "outdated" | "unreadable" | "idle"; label: string } {
    const primary = entry.integrations[0];
    if (primary) {
      if (primary.state.kind === "installed") return { tone: "installed", label: tr("Gekoppeld", "Linked") };
      if (primary.state.kind === "outdated") return { tone: "outdated", label: tr("Verouderd", "Outdated") };
      if (primary.state.kind === "unreadable") return { tone: "unreadable", label: tr("Onleesbaar", "Unreadable") };
    }
    if (entry.provider) {
      const ver = versions[entry.provider];
      const prov = workspace.provider(entry.provider);
      if (ver?.executable || prov?.executable) {
        return { tone: "installed", label: tr("Geïnstalleerd", "Installed") };
      }
      return { tone: "idle", label: tr("Niet geïnstalleerd", "Not installed") };
    }
    return { tone: "idle", label: tr("Niet gekoppeld", "Not linked") };
  }

  function entryVersion(entry: AgentEntry): string | null {
    if (!entry.provider) return null;
    if (entry.provider === "antigravity" && agSetup?.installed && agSetup.version) {
      return agSetup.version;
    }
    return versions[entry.provider]?.version ?? null;
  }

  function entryExecutable(entry: AgentEntry): string | null {
    if (!entry.provider) return null;
    return versions[entry.provider]?.executable ?? workspace.provider(entry.provider)?.executable ?? null;
  }

  function entryInstallCommand(entry: AgentEntry): string {
    if (!entry.provider) return "";
    return versions[entry.provider]?.installCommand ?? workspace.provider(entry.provider)?.installCommand ?? "";
  }

  async function prepare(i: Integration, install: boolean) {
    error = status = null;
    try {
      pending = await agentApi.prepareLink(i.target, install, i.profileId);
    } catch (e) {
      error = String(e);
    }
  }

  async function write() {
    if (!pending) return;
    const change = pending;
    pending = null;
    try {
      const backup = await agentApi.applyLink(change.id);
      status =
        (change.install
          ? tr("{title}: gekoppeld.", "{title}: linked.", { title: change.title })
          : tr("{title}: ontkoppeld.", "{title}: unlinked.", { title: change.title })) +
        (backup ? " " + tr("Backup: {path}.", "Backup: {path}.", { path: backup }) : "") +
        (change.install && change.title !== "Claude-abonnement in de balk"
          ? " " + tr("Start de agent opnieuw zodat het werkt.", "Restart the agent so it takes effect.")
          : "");
    } catch (e) {
      error = String(e);
    }
    load();
  }

  function cancel() {
    if (pending) agentApi.discardLink(pending.id);
    pending = null;
  }

  async function saveDefaultModel(provider: RunProvider, value: string) {
    if (!wsSettings) return;
    error = null;
    wsSettings.defaultModels[provider] = value.trim();
    try {
      await workspaceApi.saveSettings($state.snapshot(wsSettings));
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  async function copyCliPath(path: string) {
    try {
      await navigator.clipboard.writeText(path);
      copiedPath = true;
      setTimeout(() => (copiedPath = false), 1500);
    } catch {
      // Clipboard unavailable.
    }
  }

  async function revealPath(path: string) {
    error = null;
    try {
      await invoke("workspace_reveal_path", { path });
    } catch (e) {
      error = String(e);
    }
  }

  async function checkUpdates() {
    error = null;
    await Promise.all([loadVersions(), workspace.refresh(), loadAntigravity()]);
  }

  function installAntigravity() {
    agProgress = { phase: "downloading", fraction: 0 };
    invoke("antigravity_install").catch((e) => (agProgress = { phase: "failed", fraction: 0, error: String(e) }));
  }

  async function uninstallAntigravity() {
    error = null;
    try {
      await invoke("antigravity_uninstall");
      await loadAntigravity();
      await loadVersions();
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  async function addProfile(kind: AgentKind) {
    try {
      await agentApi.addProfile(kind, newLabel[kind] ?? "");
      newLabel[kind] = "";
    } catch (e) {
      error = String(e);
    }
    load();
  }

  async function removeProfile(p: AgentProfile) {
    if (
      !(await ask({
        question: tr("{title} uit Nook halen?", "Remove {title} from Nook?", { title: p.title }),
        detail: tr(
          "De map {folder} en de inlog blijven op je computer staan.",
          "The folder {folder} and the login stay on your computer.",
          { folder: p.displayHome },
        ),
        confirmTitle: tr("Haal weg", "Remove"),
      }))
    ) {
      return;
    }
    try {
      await agentApi.removeProfile(p.id);
    } catch (e) {
      error = String(e);
    }
    load();
  }

  async function saveKey(p: AgentProfile) {
    await agentApi.setProfileKey(p.id, keyInput[p.id] ?? "");
    keyInput[p.id] = "";
    load();
  }

  function account(p: AgentProfile): string {
    const a = agents.history?.accounts[p.id];
    if (!a) return tr("niet ingelogd", "not signed in");
    return [a.name, a.organization, a.plan].filter(Boolean).join(" · ");
  }

  // Skills helpers
  const knownProjects = $derived.by<string[]>(() => {
    const set = new Set<string>();
    for (const p of wsSettings?.favoriteProjects ?? []) if (p) set.add(p);
    for (const p of wsSettings?.recentProjects ?? []) if (p) set.add(p);
    return [...set];
  });

  const filteredSkills = $derived.by<SkillCatalogEntry[]>(() => {
    const list = skillsCatalog?.skills ?? [];
    const q = skillQuery.trim().toLowerCase();
    if (!q) return list;
    return list.filter(
      (s) =>
        s.name.toLowerCase().includes(q) ||
        s.description.toLowerCase().includes(q) ||
        s.source.toLowerCase().includes(q),
    );
  });

  function toggleSkillAgent(p: RunProvider) {
    if (skillAgents.includes(p)) {
      skillAgents = skillAgents.filter((x) => x !== p);
    } else {
      skillAgents = [...skillAgents, p];
    }
  }

  async function toggleSkillEnabled(skill: SkillCatalogEntry, enabled: boolean) {
    error = null;
    try {
      await invoke<boolean>("workspace_toggle_skill", { path: skill.path, enabled });
      if (skillsCatalog) {
        skillsCatalog = {
          ...skillsCatalog,
          skills: skillsCatalog.skills.map((s) => (s.path === skill.path ? { ...s, enabled } : s)),
        };
      }
    } catch (e) {
      error = String(e);
    }
  }

  async function inspectSkill(skill: SkillCatalogEntry) {
    if (previewPath === skill.path) {
      previewPath = null;
      previewDoc = null;
      previewError = null;
      return;
    }
    previewPath = skill.path;
    previewDoc = null;
    previewError = null;
    previewLoading = true;
    try {
      previewDoc = await invoke<SkillDocument>("workspace_read_skill", { path: skill.path });
    } catch (e) {
      previewError = String(e);
    } finally {
      previewLoading = false;
    }
  }

  async function openSkillsFolder(path: string) {
    error = null;
    try {
      await invoke("workspace_open_skills_folder", { path });
    } catch (e) {
      error = String(e);
    }
  }

  function folderBasename(path: string): string {
    const clean = path.replace(/[\\/]+$/, "");
    const idx = Math.max(clean.lastIndexOf("/"), clean.lastIndexOf("\\"));
    return idx >= 0 ? clean.slice(idx + 1) : clean;
  }

  function onTabKeys(e: KeyboardEvent) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    tab = tab === "agents" ? "skills" : "agents";
    (e.currentTarget as HTMLElement).querySelector<HTMLElement>(`[data-tab="${tab}"]`)?.focus();
  }

  const agWorking = $derived(!!agProgress && agProgress.phase !== "done" && agProgress.phase !== "failed");
  const agPhaseText = $derived(
    agProgress?.phase === "verifying"
      ? tr("Controleren…", "Verifying…")
      : agProgress?.phase === "unpacking"
        ? tr("Uitpakken…", "Unpacking…")
        : agProgress?.phase === "checking"
          ? tr("Proefstart…", "Test start…")
          : "",
  );
</script>

{#if !local}
  <p class="muted">
    {tr(
      "Coding-agents draaien op je computer, niet op je telefoon. Open Nook op je Windows- of Linux-computer om Claude Code, Codex en de andere agents te koppelen; op de telefoon zie je ze via de companion.",
      "Coding agents run on your computer, not on your phone. Open Nook on your Windows or Linux computer to link Claude Code, Codex and the other agents; on your phone you see them through the companion.",
    )}
  </p>
{:else}
  <div class="sub-tabs" role="tablist" tabindex="-1" aria-label={tr("Coding-agents en skills", "Coding agents and skills")} onkeydown={onTabKeys}>
    <button
      role="tab"
      data-tab="agents"
      class:on={tab === "agents"}
      aria-selected={tab === "agents"}
      tabindex={tab === "agents" ? 0 : -1}
      onclick={() => (tab = "agents")}
    >
      {tr("Agents", "Agents")}
    </button>
    <button
      role="tab"
      data-tab="skills"
      class:on={tab === "skills"}
      aria-selected={tab === "skills"}
      tabindex={tab === "skills" ? 0 : -1}
      onclick={() => (tab = "skills")}
    >
      {tr("Skills", "Skills")}
    </button>
  </div>

  {#if status}<p class="ok note">{status}</p>{/if}
  {#if error}<p class="err">{error}</p>{/if}

  {#if tab === "agents"}
    <div class="split">
      <div class="agent-list" role="listbox" aria-label={tr("Je agents", "Your agents")}>
        {#each agentEntries as entry (entry.id)}
          {@const standing = entryStanding(entry)}
          {@const ver = entryVersion(entry)}
          <button
            type="button"
            role="option"
            class="list-item"
            class:selected={selectedEntry?.id === entry.id}
            aria-selected={selectedEntry?.id === entry.id}
            onclick={() => (selectedId = entry.id)}
          >
            <span class="mark"><AgentMark agent={entry.name} size={22} /></span>
            <span class="item-body">
              <span class="item-head">
                <span class="item-name">{entry.name}</span>
                {#if ver}<span class="ver">{ver}</span>{/if}
              </span>
              <span class="status {standing.tone}"><span class="dot"></span>{standing.label}</span>
            </span>
          </button>
        {/each}
      </div>

      {#if selectedEntry}
        {@const standing = entryStanding(selectedEntry)}
        {@const ver = entryVersion(selectedEntry)}
        {@const exe = entryExecutable(selectedEntry)}
        {@const installCmd = entryInstallCommand(selectedEntry)}
        <div class="agent-detail">
          <div class="detail-head">
            <span class="mark"><AgentMark agent={selectedEntry.name} size={32} /></span>
            <div class="info">
              <div class="detail-title">
                <span>{selectedEntry.name}</span>
                {#if ver}<span class="badge ver-badge">{ver}</span>{/if}
              </div>
              <span class="status {standing.tone}"><span class="dot"></span>{standing.label}</span>
            </div>
          </div>

          {#if selectedEntry.integrations.length > 0}
            <h4>{tr("Koppeling met Nook", "Link with Nook")}</h4>
            <div class="group">
              {#each selectedEntry.integrations as i (i.target)}
                {@const linked = i.state.kind === "installed" || i.state.kind === "outdated"}
                <div class="row">
                  <div class="info">
                    <div class="name">{i.title}</div>
                    <div class="faint small">{stateText(i)}</div>
                    <span class="status {i.state.kind}"><span class="dot"></span>{linkWord(i)}</span>
                  </div>
                  <div class="inline">
                    {#if i.state.kind === "outdated"}
                      <button class="small" onclick={() => prepare(i, true)}>{tr("Koppeling bijwerken…", "Update link…")}</button>
                    {/if}
                    <input
                      type="checkbox"
                      role="switch"
                      aria-label={i.title}
                      title={stateText(i)}
                      checked={linked}
                      disabled={i.state.kind === "unreadable"}
                      onchange={(e) => {
                        const on = e.currentTarget.checked;
                        e.currentTarget.checked = linked;
                        prepare(i, on);
                      }}
                    />
                  </div>
                </div>
              {/each}
            </div>
            <p class="note">
              {tr(
                "Nook laat eerst precies zien wat er verandert en maakt een backup voordat er iets wordt geschreven. Draait Nook niet, dan doen de koppelingen niets. Toestemming geven vanuit de balk kan bij Claude Code en Codex; bij de andere agents beslist Nook nooit iets.",
                "Nook first shows exactly what changes and makes a backup before anything is written. If Nook isn't running, the links do nothing. Granting permission from the bar works for Claude Code and Codex; for the other agents Nook never decides anything.",
              )}
            </p>
          {/if}

          {#if selectedEntry.provider}
            {@const provider = selectedEntry.provider}
            <h4>{tr("Programma en updates", "Program & updates")}</h4>
            <div class="group">
              <div class="row">
                <div class="info">
                  <div class="name">{tr("Status en versie", "Status and version")}</div>
                  <div class="faint small">
                    {#if exe}
                      {ver
                        ? tr("Geïnstalleerd · versie {version}", "Installed · version {version}", { version: ver })
                        : tr("Geïnstalleerd", "Installed")}
                    {:else}
                      {tr("Niet gevonden op deze computer", "Not found on this computer")}
                    {/if}
                  </div>
                </div>
                <button class="small" disabled={checkingVersions} onclick={checkUpdates}>
                  {checkingVersions ? tr("Controleren…", "Checking…") : tr("Zoek naar updates", "Check for updates")}
                </button>
              </div>

              {#if exe}
                <div class="row">
                  <div class="info">
                    <div class="name">{tr("CLI-pad", "CLI path")}</div>
                    <div class="path">{exe}</div>
                  </div>
                  <div class="inline">
                    <button class="small" onclick={() => copyCliPath(exe)}>
                      {copiedPath ? tr("Gekopieerd", "Copied") : tr("Kopiëren", "Copy")}
                    </button>
                    <button class="small" onclick={() => revealPath(exe)}>
                      {tr("Map openen", "Open folder")}
                    </button>
                  </div>
                </div>
              {/if}

              {#if installCmd}
                <div class="row">
                  <div class="info">
                    <div class="name">{exe ? tr("Bijwerken", "Update") : tr("Installeren", "Install")}</div>
                    <div class="path">{installCmd}</div>
                  </div>
                  <button class="small" onclick={() => agentApi.runInTerminal(installCmd)}>
                    {tr("Draai in terminal", "Run in terminal")}
                  </button>
                </div>
              {/if}

              {#if provider === "antigravity" && agSetup?.supported}
                <div class="row">
                  <div class="info">
                    <div class="name">{tr("Antigravity ACP-server", "Antigravity ACP server")}</div>
                    <div class="faint small">
                      {#if agSetup.installed}
                        {tr("ACP-server {version} geïnstalleerd", "ACP server {version} installed", { version: agSetup.version })}
                      {:else}
                        {tr(
                          "Antigravity draait in Nook op Google's eigen ACP-server. Eenmalig installeren ({size} download).",
                          "Antigravity runs in Nook on Google's own ACP server. Install it once ({size} download).",
                          { size: `${Math.round(agSetup.downloadBytes / 1_000_000)} MB` },
                        )}
                      {/if}
                    </div>
                    {#if agProgress?.phase === "failed" && agProgress.error}
                      <div class="err">{agProgress.error}</div>
                    {/if}
                  </div>
                  <div class="inline">
                    {#if agWorking && agProgress?.phase === "downloading"}
                      <progress max="1" value={agProgress.fraction}></progress>
                      <span class="faint small">{Math.round(agProgress.fraction * 100)}%</span>
                    {:else if agWorking}
                      <span class="faint small">{agPhaseText}</span>
                    {:else if agSetup.installed}
                      <button class="ghost danger small" onclick={uninstallAntigravity}>{tr("Verwijderen", "Remove")}</button>
                    {:else}
                      <button class="small" onclick={installAntigravity}>{tr("Installeren", "Install")}</button>
                    {/if}
                  </div>
                </div>
              {/if}

              {#if wsSettings}
                <label class="row">
                  <div class="info">
                    <div class="name">{tr("Standaardmodel", "Default model")}</div>
                    <div class="faint small">
                      {tr(
                        "Leeg laat de agent zijn eigen standaardmodel kiezen.",
                        "Leave empty to let the agent pick its own default model.",
                      )}
                    </div>
                  </div>
                  <input
                    class="model-input"
                    placeholder={tr("standaard", "default")}
                    value={wsSettings.defaultModels[provider] ?? ""}
                    onchange={(e) => saveDefaultModel(provider, e.currentTarget.value)}
                  />
                </label>
              {/if}
            </div>
          {:else}
            <p class="note">
              {tr(
                "Nook volgt sessies van deze agent via zijn koppeling; je start de agent zelf in een terminal of editor.",
                "Nook follows sessions of this agent through its link; you start the agent yourself in a terminal or editor.",
              )}
            </p>
          {/if}

          {#if selectedEntry.agentKind === "claude" || selectedEntry.agentKind === "codex"}
            {@const kind = selectedEntry.agentKind}
            <h4>{tr("Accounts", "Accounts")}</h4>
            <div class="group">
              {#each profiles.filter((p) => p.kind === kind) as p (p.id)}
                <div class="row">
                  <div class="info">
                    <div class="name">
                      {p.label || (p.home ? p.title : tr("Hoofdaccount", "Main account"))}
                      {#if p.preferred}<span class="badge">{tr("standaard", "default")}</span>{/if}
                    </div>
                    <div class="faint small">{account(p)} · {p.displayHome}</div>
                    {#if kind === "claude" && p.auth === "apiKey"}
                      <div class="inline key">
                        <input
                          type="password"
                          placeholder={p.hasKey ? tr("Sleutel staat in de kluis", "Key is in the keychain") : "sk-ant-…"}
                          bind:value={keyInput[p.id]}
                        />
                        <button onclick={() => saveKey(p)}>
                          {keyInput[p.id] ? tr("Bewaar", "Save") : p.hasKey ? tr("Wis", "Clear") : tr("Bewaar", "Save")}
                        </button>
                      </div>
                    {/if}
                  </div>
                  <div class="inline">
                    {#if !p.preferred}
                      <button class="ghost" onclick={() => agentApi.preferProfile(p.id).then(load)}>
                        {tr("Maak standaard", "Make default")}
                      </button>
                    {/if}
                    {#if kind === "claude"}
                      <select
                        value={p.auth ?? "cli"}
                        onchange={(e) => agentApi.setProfileAuth(p.id, e.currentTarget.value as "cli" | "apiKey").then(load)}
                      >
                        <option value="cli">{tr("Abonnement (inloggen)", "Subscription (sign in)")}</option>
                        <option value="apiKey">{tr("API-sleutel", "API key")}</option>
                      </select>
                    {/if}
                    <button
                      class="ghost"
                      title={tr("Inloggen in een terminal", "Sign in in a terminal")}
                      onclick={() => agentApi.runInTerminal(p.loginCommand)}
                    >
                      {tr("Log in…", "Sign in…")}
                    </button>
                    {#if p.home}
                      <button class="ghost danger" onclick={() => removeProfile(p)}>{tr("Haal weg", "Remove")}</button>
                    {/if}
                  </div>
                </div>
              {/each}

              {#if selectedEntry.extraIntegrations.length > 0}
                {#each selectedEntry.extraIntegrations as i (i.target + i.profileId)}
                  <div class="row">
                    <div class="info">
                      <div class="name">{i.title}</div>
                      <div class="faint small">{stateText(i)}</div>
                    </div>
                    {#if i.state.kind === "installed"}
                      <button class="small" onclick={() => prepare(i, false)}>{tr("Ontkoppel…", "Unlink…")}</button>
                    {:else if i.state.kind !== "unreadable"}
                      <button class="small" onclick={() => prepare(i, true)}>
                        {i.state.kind === "outdated" ? tr("Werk bij…", "Update…") : tr("Koppel…", "Link…")}
                      </button>
                    {/if}
                  </div>
                {/each}
              {/if}

              <div class="row">
                <input
                  placeholder={tr("Naam van een extra account, bijvoorbeeld Werk", "Name of an extra account, for example Work")}
                  bind:value={newLabel[kind]}
                />
                <button onclick={() => addProfile(kind)}>{tr("Voeg account toe", "Add account")}</button>
              </div>
            </div>
            <p class="faint note">
              {tr(
                "Elk account heeft een eigen map (bijvoorbeeld ~/.claude-werk) met een eigen inlog, zodat privé en werk naast elkaar kunnen. Een API-sleutel staat alleen in de kluis van je systeem, nooit in een bestand.",
                "Each account has its own folder (for example ~/.claude-work) with its own login, so personal and work can live side by side. An API key is only kept in your system's keychain, never in a file.",
              )}
            </p>
          {/if}
        </div>
      {/if}
    </div>
  {:else}
    <!-- Skills tab (`SkillsSettingsSection` on the Mac) -->
    <h3>{tr("Waar skills komen", "Where skills go")}</h3>
    <p class="section-info">
      {tr(
        "Een skill is een map met een SKILL.md die een agent vertelt hoe iets moet. Nook zet hem in de map die elke agent leest: voor jezelf krijgt elk project hem; voor één project komt hij in dat project en gaat hij mee in de commits.",
        "A skill is a folder with a SKILL.md that tells an agent how to do something. Nook puts it in the folder each agent reads: for yourself, every project gets it; for one project, it goes in that project and is committed with it.",
      )}
    </p>
    <div class="group">
      <label class="row">
        <span>
          {tr("Bereik", "Scope")}<br />
          <small>
            {skillProject
              ? tr("In de map van dit project; hij gaat mee in de commits", "In this project's folder; it is committed with the project")
              : tr("In je eigen skill-mappen, voor elk project", "In your own skills folders, for every project")}
          </small>
        </span>
        <select bind:value={skillProject}>
          <option value="">{tr("Jezelf (elk project)", "Yourself (every project)")}</option>
          {#each knownProjects as project (project)}
            <option value={project}>{folderBasename(project)} ({project})</option>
          {/each}
        </select>
      </label>

      <div class="row stacked-row">
        <span>
          {tr("Agents", "Agents")}<br />
          <small>{tr("Agents die dezelfde map lezen, delen één kopie", "Agents that read the same folder share one copy")}</small>
        </span>
        <div class="chip-row">
          <button type="button" class="chip" class:active={skillAgents.length === 0} onclick={() => (skillAgents = [])}>
            {tr("Alle agents", "All agents")}
          </button>
          {#each RUNNABLE_ORDER as p (p)}
            {@const label = workspace.provider(p)?.name ?? agentNames[p as AgentKind] ?? p}
            <button type="button" class="chip" class:active={skillAgents.includes(p)} onclick={() => toggleSkillAgent(p)}>
              <AgentMark agent={label} size={13} />{label}
            </button>
          {/each}
        </div>
      </div>
    </div>

    <h3>{tr("Ontdekte skills", "Discovered skills")}</h3>
    <div class="group">
      <div class="row">
        <input
          type="search"
          class="skill-search"
          placeholder={tr("Skills filteren…", "Filter skills…")}
          aria-label={tr("Skills filteren…", "Filter skills…")}
          bind:value={skillQuery}
        />
        <button class="small" disabled={skillsLoading} onclick={loadSkills}>
          {skillsLoading ? tr("Laden…", "Loading…") : tr("Vernieuwen", "Refresh")}
        </button>
      </div>

      {#if skillsLoading && !skillsCatalog}
        <div class="row"><span class="faint">{tr("Laden…", "Loading…")}</span></div>
      {:else if filteredSkills.length === 0}
        <div class="row">
          <div class="info">
            <div class="name">{tr("Geen skills gevonden", "No skills found")}</div>
            <div class="faint small">
              {tr(
                "Zet een map met een SKILL.md in een van de skill-mappen hieronder en klik op Vernieuwen.",
                "Place a folder with a SKILL.md in one of the skill folders below and click Refresh.",
              )}
            </div>
          </div>
        </div>
      {:else}
        {#each filteredSkills as skill (skill.path)}
          <div class="skill-block">
            <div class="row skill-row">
              <div class="info">
                <div class="name">
                  <span class:disabled-name={!skill.enabled}>{skill.name}</span>
                  <span class="badge">
                    {skill.scope === "project" ? tr("Project", "Project") : tr("Globaal", "Global")}
                  </span>
                  <span class="badge source-badge">{skill.source}</span>
                </div>
                {#if skill.description}
                  <div class="faint small">{skill.description}</div>
                {/if}
                <div class="faint small">
                  {skill.providers.map((p) => workspace.provider(p)?.name ?? p).join(" · ")}
                </div>
              </div>
              <div class="inline">
                <button class="small" onclick={() => inspectSkill(skill)}>
                  {previewPath === skill.path ? tr("Verbergen", "Hide") : tr("Bekijken", "Inspect")}
                </button>
                <button class="small" onclick={() => openSkillsFolder(skill.folder)}>
                  {tr("Map openen", "Open folder")}
                </button>
                <input
                  type="checkbox"
                  role="switch"
                  aria-label={skill.name}
                  checked={skill.enabled}
                  onchange={(e) => toggleSkillEnabled(skill, e.currentTarget.checked)}
                />
              </div>
            </div>

            {#if previewPath === skill.path}
              <div class="skill-preview">
                {#if previewLoading}
                  <p class="faint small">{tr("Laden…", "Loading…")}</p>
                {:else if previewError}
                  <p class="err">{previewError}</p>
                {:else if previewDoc}
                  <div class="preview-meta">
                    <span class="path">{previewDoc.path}</span>
                    {#if previewDoc.scripts.length > 0}
                      <span class="scripts-warn">
                        {tr("Bevat {n} scripts die een agent kan uitvoeren.", "Comes with {n} scripts an agent can run.", {
                          n: previewDoc.scripts.length,
                        })}
                        ({previewDoc.scripts.join(", ")})
                      </span>
                    {:else}
                      <span class="faint small">{tr("Geen scripts: alleen instructies.", "No scripts: instructions only.")}</span>
                    {/if}
                  </div>
                  <pre class="skill-doc">{previewDoc.content}</pre>
                {/if}
              </div>
            {/if}
          </div>
        {/each}
      {/if}
    </div>

    {#if skillsCatalog && skillsCatalog.folders.length > 0}
      <h3>{tr("Skill-mappen", "Skill folders")}</h3>
      <div class="group">
        {#each skillsCatalog.folders as folder (folder.path)}
          <div class="row">
            <div class="info">
              <div class="name">
                <span>{folder.label}</span>
                <span class="badge">
                  {folder.scope === "project" ? tr("Project", "Project") : tr("Globaal", "Global")}
                </span>
                <span class="faint small">
                  {folder.count === 1
                    ? tr("1 skill", "1 skill")
                    : tr("{n} skills", "{n} skills", { n: folder.count })}
                </span>
              </div>
              <div class="path">{folder.path}</div>
            </div>
            <button class="small" onclick={() => openSkillsFolder(folder.path)}>
              {folder.exists ? tr("Map openen", "Open folder") : tr("Aanmaken en openen", "Create and open")}
            </button>
          </div>
        {/each}
      </div>
    {/if}
  {/if}
{/if}

{#if pending}
  <div class="modal" role="dialog" aria-modal="true">
    <div class="sheet">
      <h3>
        {pending.install
          ? tr("Koppel {title}", "Link {title}", { title: pending.title })
          : tr("Ontkoppel {title}", "Unlink {title}", { title: pending.title })}
      </h3>
      {#if pending.unchanged}
        <p class="muted">{tr("Er verandert niets.", "Nothing changes.")}</p>
      {:else}
        <p class="muted small">
          {tr(
            "Dit verandert in {path}. Je eigen instellingen blijven staan; er komt eerst een backup naast het bestand.",
            "This changes in {path}. Your own settings stay; a backup is made next to the file first.",
            { path: pending.path },
          )}
        </p>
        <DiffView lines={pending.preview} max={360} />
      {/if}
      <div class="inline end">
        <button class="ghost" onclick={cancel}>{tr("Annuleer", "Cancel")}</button>
        <button class="primary" disabled={pending.unchanged} onclick={write}>
          {pending.install ? tr("Koppel", "Link") : tr("Ontkoppel", "Unlink")}
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .sub-tabs {
    display: inline-flex;
    align-self: flex-start;
    gap: var(--space-2);
    background: var(--graphite);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
    padding: var(--space-2);
    margin-bottom: var(--space-12);
  }
  .sub-tabs button {
    flex: none;
    border: none;
    background: none;
    color: var(--text2);
    padding: var(--space-4) var(--space-12);
    border-radius: var(--radius-chip);
    font: var(--text-detail);
    font-weight: 500;
  }
  .sub-tabs button:hover:not(:disabled) {
    background: color-mix(in srgb, var(--paper) 6%, transparent);
    color: var(--paper);
  }
  .sub-tabs button.on,
  .sub-tabs button.on:hover:not(:disabled) {
    background: color-mix(in srgb, var(--paper) 14%, transparent);
    color: var(--paper);
  }

  .split {
    display: grid;
    grid-template-columns: minmax(190px, 230px) minmax(0, 1fr);
    gap: var(--space-16);
    align-items: start;
  }
  .agent-list {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    background: var(--graphite);
    border: 1px solid var(--line2);
    border-radius: var(--radius-panel);
    padding: var(--space-6);
  }
  .list-item {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    width: 100%;
    text-align: left;
    border: none;
    background: transparent;
    padding: var(--space-8);
    border-radius: var(--radius-control);
    color: var(--text2);
  }
  .list-item:hover {
    background: color-mix(in srgb, var(--paper) 6%, transparent);
  }
  .list-item.selected {
    background: color-mix(in srgb, var(--paper) 12%, transparent);
    color: var(--paper);
  }
  .mark {
    flex: none;
    display: grid;
  }
  .item-body {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
    flex: 1;
  }
  .item-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: var(--space-6);
  }
  .item-name {
    font: var(--text-emphasis);
    color: var(--paper);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .ver {
    font: var(--text-code);
    color: var(--text3);
    flex: none;
  }

  .agent-detail {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .agent-detail h4 {
    margin: var(--space-16) 0 var(--space-6);
    font: var(--text-emphasis);
    color: var(--text2);
  }
  .detail-head {
    display: flex;
    align-items: center;
    gap: var(--space-12);
    padding-bottom: var(--space-8);
    border-bottom: 1px solid var(--separator);
  }
  .detail-title {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    font: var(--text-title);
    color: var(--paper);
  }

  .status {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    font: var(--text-detail);
    color: var(--text2);
  }
  .status .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--text3);
  }
  .status.installed .dot {
    background: var(--mint);
  }
  .status.outdated .dot {
    background: var(--amber);
  }
  .status.outdated {
    color: var(--amber);
  }
  .status.unreadable .dot {
    background: var(--coral);
  }

  .info {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    min-width: 0;
    flex: 1;
  }
  .name {
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: var(--space-6);
    color: var(--paper);
  }
  .small {
    font: var(--text-detail);
  }
  .path {
    font: var(--text-code);
    color: var(--text2);
    word-break: break-all;
    user-select: text;
  }
  .badge {
    font: var(--text-caption);
    background: var(--smoke);
    border-radius: var(--radius-chip);
    padding: var(--space-2) var(--space-6);
    color: var(--text2);
  }
  .ver-badge {
    font: var(--text-code);
  }
  .source-badge {
    font: var(--text-code);
  }
  .ok {
    color: var(--mint);
  }
  .err {
    color: var(--coral);
    font: var(--text-detail);
  }
  .inline {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    flex-wrap: wrap;
  }
  .key input {
    width: 220px;
  }
  .model-input {
    width: 200px;
  }
  .row input:not([type="checkbox"]) {
    flex: 1;
  }
  progress {
    width: 90px;
    accent-color: var(--paper);
  }

  .stacked-row {
    flex-direction: column;
    align-items: stretch;
    gap: var(--space-8);
  }
  .chip-row {
    display: flex;
    flex-wrap: wrap;
    gap: var(--space-6);
  }
  .chip {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    border: 1px solid var(--line2);
    background: var(--graphite);
    color: var(--text2);
    border-radius: var(--radius-pill);
    padding: var(--space-4) var(--space-10);
    font: var(--text-detail);
  }
  .chip.active {
    background: color-mix(in srgb, var(--paper) 14%, transparent);
    border-color: var(--paper);
    color: var(--paper);
  }

  .skill-search {
    min-width: 180px;
  }
  .skill-block {
    display: flex;
    flex-direction: column;
  }
  .disabled-name {
    color: var(--text3);
    text-decoration: line-through;
  }
  .skill-preview {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    padding: var(--space-10) var(--space-12);
    margin-bottom: var(--space-8);
    background: var(--graphite);
    border: 1px solid var(--line2);
    border-radius: var(--radius-control);
  }
  .preview-meta {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
  }
  .scripts-warn {
    font: var(--text-detail);
    color: var(--amber);
  }
  .skill-doc {
    margin: 0;
    max-height: 280px;
    overflow: auto;
    font: var(--text-code);
    color: var(--text2);
    white-space: pre-wrap;
    word-break: break-word;
    user-select: text;
  }

  .modal {
    position: fixed;
    inset: 0;
    background: color-mix(in srgb, black 55%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 20;
  }
  .sheet {
    background: var(--graphite);
    border: 1px solid var(--line2);
    border-radius: var(--radius-composer);
    padding: var(--space-16) var(--space-18);
    width: min(720px, 92vw);
    max-height: 86vh;
    display: flex;
    flex-direction: column;
    gap: var(--space-10);
  }
  .sheet h3 {
    margin: 0;
    color: var(--paper);
    font: var(--text-title);
  }
  .end {
    justify-content: flex-end;
  }

  @media (max-width: 700px) {
    .split {
      grid-template-columns: 1fr;
    }
  }
</style>
