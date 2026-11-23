<script lang="ts">
  // Settings › Coding agents › Skills (`SkillsSettingsSection` on the Mac): where skills go (you or one project, and
  // for which agents), the skills those agents read, each with its SKILL.md and scripts to check and a switch that turns
  // it off without deleting it, and the folders they live in. The Mac's search on skills.sh and its collections are not
  // here: the Windows app does not install skills from the internet (docs/WINDOWS-PARITY.md).
  import { invoke } from "@tauri-apps/api/core";
  import { tr } from "../../lib/i18n.svelte";
  import { nook } from "../../lib/state.svelte";
  import { agentNames, type AgentKind } from "../../lib/agents";
  import type { RunProvider } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ListEmptyNote from "../../components/ui/ListEmptyNote.svelte";
  import Menu from "../../components/ui/Menu.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import Tag from "../../components/ui/Tag.svelte";
  import ConnectionRow from "./ConnectionRow.svelte";

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
  interface SkillFolderInfo { path: string; label: string; scope: "user" | "project"; exists: boolean; count: number }
  interface SkillsCatalogView { skills: SkillCatalogEntry[]; folders: SkillFolderInfo[] }
  interface SkillDocument { path: string; name: string; description: string; content: string; scripts: string[] }

  const PROVIDERS: RunProvider[] = ["claude", "codex", "gemini", "antigravity", "opencode", "cursor", "grok"];

  const local = $derived(nook.info?.capabilities.localAgents ?? false);

  let project = $state("");
  /** The agents chosen; empty means all of them. */
  let chosen = $state<RunProvider[]>([]);
  let query = $state("");
  let catalog = $state<SkillsCatalogView | null>(null);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let docs = $state<Record<string, SkillDocument | string>>({});
  let agentMenu = $state<DOMRect | null>(null);

  async function load() {
    if (!local) return;
    loading = true;
    error = null;
    try {
      catalog = await invoke<SkillsCatalogView>("workspace_skills_catalog", {
        project: project || null,
        providers: chosen.length > 0 ? chosen : null,
      });
    } catch (e) {
      error = String(e);
    } finally {
      loading = false;
    }
  }

  $effect(() => {
    void project;
    void chosen.length;
    load();
  });
  $effect(() => {
    if (local) workspace.start();
  });

  const projects = $derived([...new Set([...(workspace.settings?.favoriteProjects ?? []), ...(workspace.settings?.recentProjects ?? [])].filter(Boolean))]);

  const shown = $derived.by(() => {
    const list = catalog?.skills ?? [];
    const q = query.trim().toLowerCase();
    return q ? list.filter((s) => s.name.toLowerCase().includes(q) || s.description.toLowerCase().includes(q)) : list;
  });

  function providerName(p: RunProvider): string {
    return workspace.provider(p)?.name ?? agentNames[p as AgentKind] ?? p;
  }

  const agentSummary = $derived(
    chosen.length === 0 || chosen.length === PROVIDERS.length ? tr("Alle agents", "All agents") : PROVIDERS.filter((p) => chosen.includes(p)).map(providerName).join(", "),
  );

  function toggleAgent(p: RunProvider) {
    const now = chosen.length === 0 ? [...PROVIDERS] : [...chosen];
    const next = now.includes(p) ? now.filter((x) => x !== p) : [...now, p];
    // At least one agent stays chosen, as on the Mac.
    if (next.length === 0) return;
    chosen = next.length === PROVIDERS.length ? [] : next;
  }

  function base(path: string): string {
    const clean = path.replace(/[\\/]+$/, "");
    return clean.slice(Math.max(clean.lastIndexOf("/"), clean.lastIndexOf("\\")) + 1);
  }

  async function setEnabled(skill: SkillCatalogEntry, enabled: boolean) {
    error = null;
    try {
      await invoke<boolean>("workspace_toggle_skill", { path: skill.path, enabled });
      if (catalog) catalog = { ...catalog, skills: catalog.skills.map((s) => (s.path === skill.path ? { ...s, enabled } : s)) };
    } catch (e) {
      error = String(e);
    }
  }

  async function readDoc(skill: SkillCatalogEntry) {
    if (docs[skill.path]) return;
    try {
      docs[skill.path] = await invoke<SkillDocument>("workspace_read_skill", { path: skill.path });
    } catch (e) {
      docs[skill.path] = String(e);
    }
  }

  async function openFolder(path: string) {
    error = null;
    try {
      await invoke("workspace_open_skills_folder", { path });
    } catch (e) {
      error = String(e);
    }
  }
</script>

{#if !local}
  <p class="muted">
    {tr(
      "Coding-agents draaien op je computer, niet op je telefoon. Open Nook op je Windows- of Linux-computer om Claude Code, Codex en de andere agents te koppelen; op de telefoon zie je ze via de companion.",
      "Coding agents run on your computer, not on your phone. Open Nook on your Windows or Linux computer to link Claude Code, Codex and the other agents; on your phone you see them through the companion.",
    )}
  </p>
{:else}
  {#if error}<p class="err">{error}</p>{/if}

  <h3>{tr("Waar skills komen", "Where skills go")}</h3>
  <p class="section-info">
    {tr(
      "Een skill is een map met een SKILL.md die een agent vertelt hoe iets moet. Voor jezelf leest elk project hem; voor één project staat hij in dat project en gaat hij mee in de commits.",
      "A skill is a folder with a SKILL.md that tells an agent how to do something. For yourself, every project reads it; for one project, it lives in that project and is committed with it.",
    )}
  </p>
  <div class="group">
    <label class="row">
      <span>
        {tr("Voor", "For")}<br />
        <small>{project ? tr("In de map van dit project; hij gaat mee in de commits", "In this project's folder; it is committed with the project") : tr("In je eigen skill-mappen, voor elk project", "In your own skills folders, for every project")}</small>
      </span>
      <select bind:value={project}>
        <option value="">{tr("Jezelf (elk project)", "Yourself (every project)")}</option>
        {#each projects as path (path)}
          <option value={path} title={path}>{base(path)}</option>
        {/each}
      </select>
    </label>
    <div class="row">
      <span>
        {tr("Agents", "Agents")}<br />
        <small>{tr("Agents die dezelfde map lezen, delen één kopie", "Agents that read the same folder share one copy")}</small>
      </span>
      <button type="button" class="menu-btn" onclick={(e) => (agentMenu = e.currentTarget.getBoundingClientRect())}>
        {agentSummary}<Ico name="chevron-down" size={12} />
      </button>
    </div>
  </div>

  <div class="section-head">
    <h3>{tr("Skills van je agents", "Your agents' skills")}</h3>
    <button type="button" class="head-action" disabled={loading} onclick={load}>
      <Ico name="refresh-cw" size={14} />{tr("Vernieuwen", "Refresh")}
    </button>
  </div>
  <p class="section-info">
    {tr(
      "De skills die de gekozen agents hier lezen. Lees de SKILL.md en de scripts van een skill voordat een agent hem gebruikt; de schakelaar zet een skill uit zonder hem te verwijderen.",
      "The skills the chosen agents read here. Read a skill's SKILL.md and scripts before an agent uses it; the switch turns a skill off without deleting it.",
    )}
  </p>
  <div class="group">
    {#if (catalog?.skills.length ?? 0) > 6}
      <div class="row filter"><SearchField bind:value={query} placeholder={tr("Filteren", "Filter")} /></div>
    {/if}
    {#if loading && !catalog}
      <p class="empty-note">{tr("Laden…", "Loading…")}</p>
    {:else if (catalog?.skills.length ?? 0) === 0}
      <div class="empty">
        <strong>{tr("Geen skills gevonden", "No skills found")}</strong>
        <span>{tr("Zet een map met een SKILL.md in een van de skill-mappen hieronder en klik op Vernieuwen.", "Place a folder with a SKILL.md in one of the skill folders below and click Refresh.")}</span>
      </div>
    {:else if shown.length === 0}
      <ListEmptyNote text={tr("Geen skills gevonden", "No skills found")} />
    {/if}
    {#each shown as skill (skill.path)}
      {@const doc = docs[skill.path]}
      <ConnectionRow
        title={skill.name}
        status={[skill.scope === "project" ? tr("Project", "Project") : tr("Jezelf", "Yourself"), skill.providers.map(providerName).join(", ")].join(" · ")}
        on={skill.enabled}
        onToggle={(on) => setEnabled(skill, on)}
        menu={[{ label: tr("Map openen", "Open folder"), icon: "folder", onselect: () => openFolder(skill.folder) }]}
        onopen={() => readDoc(skill)}
      >
        {#snippet icon()}<Ico name="book" size={16} />{/snippet}
        {#snippet expanded()}
          {#if skill.description}<p class="text">{skill.description}</p>{/if}
          <div class="kv"><span>{tr("Bron", "Source")}</span><span class="mono">{skill.folder}</span></div>
          {#if typeof doc === "string"}
            <p class="err">{doc}</p>
          {:else if doc}
            {#if doc.scripts.length > 0}
              <p class="warn">{tr("Bevat {n} scripts die een agent kan uitvoeren.", "Comes with {n} scripts an agent can run.", { n: doc.scripts.length })}</p>
              <div class="scripts">{#each doc.scripts as s (s)}<span class="mono">{s}</span>{/each}</div>
            {:else}
              <p class="ok">{tr("Geen scripts: alleen instructies.", "No scripts: instructions only.")}</p>
            {/if}
            <div class="part-title">SKILL.md</div>
            <pre class="doc">{doc.content}</pre>
          {:else}
            <p class="faint">{tr("Laden…", "Loading…")}</p>
          {/if}
        {/snippet}
      </ConnectionRow>
    {/each}
  </div>

  {#if catalog && catalog.folders.length > 0}
    <h3>{tr("Skill-mappen", "Skill folders")}</h3>
    <p class="section-info">{tr("De mappen die de gekozen agents lezen. Agents die dezelfde map lezen, delen één kopie.", "The folders the chosen agents read. Agents that read the same folder share one copy.")}</p>
    <div class="group">
      {#each catalog.folders as folder (folder.path)}
        <div class="row folder">
          <span class="folder-text">
            <span class="folder-name">{folder.label}{#if folder.scope === "project"}<Tag text={tr("Project", "Project")} />{/if}</span>
            <span class="mono faint">{folder.path}</span>
          </span>
          <span class="faint small">{folder.exists ? (folder.count === 1 ? tr("1 skill", "1 skill") : tr("{n} skills", "{n} skills", { n: folder.count })) : tr("Bestaat nog niet", "Doesn't exist yet")}</span>
          <button class="small" onclick={() => openFolder(folder.path)}>{folder.exists ? tr("Map openen", "Open folder") : tr("Aanmaken en openen", "Create and open")}</button>
        </div>
      {/each}
    </div>
  {/if}
{/if}

{#if agentMenu}
  <Menu
    anchor={agentMenu}
    onclose={() => (agentMenu = null)}
    sections={[PROVIDERS.map((p) => ({ label: providerName(p), checked: chosen.length === 0 || chosen.includes(p), onselect: () => toggleAgent(p) }))]}
  />
{/if}

<style>
  .menu-btn { display: inline-flex; align-items: center; gap: var(--space-6); max-width: 260px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .filter { padding: var(--space-8) 0; }
  .filter :global(> *) { flex: 1; }
  .empty { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-12) 0; }
  .empty strong { font: var(--text-emphasis); color: var(--paper); }
  .empty span { font: var(--text-detail); color: var(--text2); }
  .text { margin: 0; font: var(--text-detail); line-height: 1.4; color: var(--text2); }
  .kv { display: flex; justify-content: space-between; gap: var(--space-16); font: var(--text-body); color: var(--paper); }
  .mono { font: var(--text-code); color: var(--text2); word-break: break-all; user-select: text; }
  .kv .mono { text-align: right; }
  .warn { margin: 0; font: var(--text-detail); color: var(--amber); }
  .ok { margin: 0; font: var(--text-detail); color: var(--mint); }
  .err { color: var(--coral); font: var(--text-detail); }
  .scripts { display: flex; flex-direction: column; gap: var(--space-2); }
  .part-title { font: var(--text-emphasis); color: var(--paper); }
  .doc { margin: 0; max-height: 260px; overflow: auto; font: var(--text-code); color: var(--text2); white-space: pre-wrap; word-break: break-word; user-select: text; }
  .folder { flex-wrap: nowrap; }
  .folder-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .folder-name { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-emphasis); color: var(--paper); }
  .small { font: var(--text-detail); }
</style>
