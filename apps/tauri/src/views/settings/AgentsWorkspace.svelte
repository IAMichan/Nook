<script lang="ts">
  // Settings › Sessions, Worktrees and the workspace for agents (`WorkspaceSettingsSection` on the Mac): one component,
  // shown one part at a time where the Mac has it (`part`).
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agents } from "../../lib/agents.svelte";
  import { permissionLabels, toolsApi, workspaceApi, type PermissionPolicy, type RunProvider, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { automationApi, type AutomationOverview } from "../../lib/workspace/automation";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import Fold from "./Fold.svelte";

  let { part = "sessions" }: { part?: "sessions" | "worktrees" | "openIn" | "bridge" } = $props();
  let editors = $state<{ id: string; name: string }[]>([]);
  $effect(() => {
    if (part === "openIn") workspaceApi.editors().then((e) => (editors = e)).catch(() => {});
  });

  let s = $state<WorkspaceSettings | null>(null);
  let error = $state<string | null>(null);
  let linked = $state<string | null>(null);

  $effect(() => {
    workspace.start().then(() => (s = workspace.settings ? { ...workspace.settings } : null));
  });

  async function save() {
    if (!s) return;
    try {
      await workspaceApi.saveSettings($state.snapshot(s));
      await workspace.refresh();
    } catch (e) {
      error = String(e);
    }
  }

  // Writing titles by itself is stored with the automation settings.
  let automation = $state<AutomationOverview | null>(null);
  $effect(() => {
    if (part === "sessions") automationApi.overview().then((o) => (automation = o)).catch(() => {});
  });
  async function saveAutomation() {
    if (!automation) return;
    try {
      await automationApi.saveSettings($state.snapshot(automation.settings));
    } catch (e) {
      error = String(e);
    }
  }

  /// " Team/Michan " → "team/michan", as the core cleans it (`normalized_branch_prefix`); empty is "nook".
  function normalizedPrefix(raw: string): string {
    const parts = raw.split("/").map((p) => p.trim()).filter((p) => /[\p{L}\p{N}]/u.test(p))
      .map((p) => p.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32).replace(/-+$/, ""))
      .filter(Boolean);
    return parts.length ? parts.join("/") : "nook";
  }

  async function chooseRoot() {
    const picked = await openDialog({ directory: true, multiple: false }).catch(() => null);
    if (typeof picked === "string" && s) {
      s.worktreeRoot = picked;
      save();
    }
  }

  async function link(p: RunProvider) {
    error = null;
    try {
      await toolsApi.linkBridge(p);
      linked = tr("Het commando draait in een terminal van Nook (Agents › Alle terminals).", "The command runs in a Nook terminal (Agents › All terminals).");
      agents.select("terminals");
    } catch (e) {
      error = String(e);
    }
  }

  const providers = $derived(workspace.providers.filter((p) => p.supported));
  const policies = $derived<PermissionPolicy[]>(workspace.provider(s?.defaultProvider ?? "claude")?.capabilities.policies ?? ["acceptEdits"]);
</script>

{#if s && part === "sessions"}
  <!-- Sessions (`WorkspaceSettingsSection`, part sessions): what a new session suggests, the model per agent folded
       away, how sessions behave, what happens when one stops, and tidying up. -->
  <h3>{tr("Nieuwe sessie", "New session")}</h3>
  <p class="section-info">{tr("Wat een nieuwe sessie voorstelt; kies je daar iets anders, dan onthoudt Nook dat.", "What a new session suggests; if you pick something else there, Nook remembers it.")}</p>
  <div class="group">
    <label class="row"><span>{tr("Standaard-agent", "Default agent")}</span>
      <select bind:value={s.defaultProvider} onchange={save}>{#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}</select>
    </label>
    <label class="row"><span>{tr("Standaardmodus", "Default mode")}</span>
      <select bind:value={s.defaultMode} onchange={save}><option value="agent">Agent</option><option value="plan">Plan</option></select>
    </label>
    <label class="row"><span>{tr("Standaardrechten", "Default permissions")}</span>
      <select bind:value={s.defaultPermission} onchange={save}>{#each policies as p (p)}<option value={p}>{permissionLabels[p]}</option>{/each}</select>
    </label>
    <label class="row"><span>{tr("Standaard-isolatie", "Default isolation")}</span>
      <select bind:value={s.defaultIsolation} onchange={save}><option value="worktree">{tr("Nieuwe Git-worktree", "New Git worktree")}</option><option value="folder">{tr("Huidige map", "Current folder")}</option></select>
    </label>
  </div>

  <Fold title={tr("Model per agent", "Model per agent")} summary={s.defaultModels[s.defaultProvider] || tr("standaard", "default")}>
    {#each providers as p (p.provider)}
      <label class="row"><span class="agent-name"><AgentMark agent={p.name} size={14} />{p.name}</span>
        <input class="model" placeholder={tr("standaard", "default")} value={s.defaultModels[p.provider] ?? ""} onchange={(e) => { s!.defaultModels[p.provider] = (e.target as HTMLInputElement).value.trim(); save(); }} />
      </label>
    {/each}
  </Fold>

  <h3>{tr("Gedrag", "Behavior")}</h3>
  <div class="group">
    {#if automation}
      <label class="row"><span>{tr("Sessietitels automatisch laten schrijven (klein model)", "Write session titles automatically (small model)")}</span>
        <input type="checkbox" role="switch" bind:checked={automation.settings.autoTitles} onchange={saveAutomation} />
      </label>
      <label class="row stacked">
        <span>{tr("Eigen regels voor titels", "Your own rules for titles")}</span>
        <input placeholder={tr("Begin met het ticketnummer, schrijf in het Engels", "Start with the ticket number, write in English")}
          value={automation.settings.titleInstructions ?? ""} onchange={(e) => { automation!.settings.titleInstructions = e.currentTarget.value.trim(); saveAutomation(); }} />
      </label>
    {/if}
    <label class="row stacked">
      <span>{tr("Instructies voor elke agent", "Instructions for every agent")}<br /><small>{tr("Nook geeft ze bij de start aan elke coding agent, voor de eigen instructies van de sessie, ook aan agents die geen CLAUDE.md of AGENTS.md lezen. Een wijziging telt vanaf de volgende start van een agent.", "Nook gives these to every coding agent at launch, before the session's own instructions, also to agents that read no CLAUDE.md or AGENTS.md. A change counts from an agent's next start.")}</small></span>
      <textarea rows="3" placeholder={tr("Regels die elke agent hier volgt, bijv. “Draai de tests voor je commit.”", "Rules every agent follows here, e.g. “Run the tests before you commit.”")}
        value={s.agentInstructions ?? ""} onchange={(e) => { s!.agentInstructions = e.currentTarget.value.trim(); save(); }}></textarea>
    </label>
    <label class="row"><span>{tr("Een bericht tijdens een beurt stuurt de agent bij (Ctrl+Enter zet het in de wachtrij)", "A message during a turn steers the agent (Ctrl+Enter queues it)")}</span><input type="checkbox" role="switch" bind:checked={s.steerByDefault} onchange={save} /></label>
    <label class="row">
      <span>{tr("Sessies tegelijk aan het werk", "Sessions working at once")}<br /><small>{tr("Hooguit zoveel sessies werken tegelijk; een nieuwe beurt daarboven wacht en start zodra de beurt van een andere sessie klaar is.", "At most this many sessions work at the same time; a new turn past it waits and starts as soon as another session's turn ends.")}</small></span>
      <select value={s.maxWorkingSessions ?? 0} onchange={(e) => { s!.maxWorkingSessions = Number(e.currentTarget.value); save(); }}>
        <option value={0}>{tr("Geen limiet", "No limit")}</option>
        {#each [2, 3, 4, 6, 8] as count (count)}<option value={count}>{count}</option>{/each}
      </select>
    </label>
  </div>

  <h3>{tr("Als een sessie stopt of Nook herstart", "When a session stops or Nook restarts")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Na een gebruikslimiet vanzelf verdergaan zodra die vrij is", "Resume automatically once a usage limit resets")}</span><input type="checkbox" role="switch" bind:checked={s.autoResumeLimited} onchange={save} /></label>
  </div>

  <h3>{tr("Opruimen", "Tidying up")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Automatisch archiveren na", "Archive automatically after")}</span>
      <select bind:value={s.autoArchiveDays} onchange={save}>
        <option value={0}>{tr("Nooit", "Never")}</option><option value={1}>{tr("1 dag", "1 day")}</option>{#each [7, 30, 90] as n (n)}<option value={n}>{tr("{n} dagen", "{n} days", { n })}</option>{/each}
      </select>
    </label>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else if s && part === "worktrees"}
  <!-- Worktrees (part worktrees): where a new worktree goes. -->
  <h3>{tr("Nieuwe worktrees", "New worktrees")}</h3>
  <div class="group">
    <div class="row"><span>{tr("Map voor worktrees", "Worktree folder")}</span>
      <span class="inline"><span class="path">{s.worktreeRoot || "~/.nook/worktrees"}</span><button class="small" onclick={chooseRoot}>{tr("Wijzig…", "Change…")}</button>
        {#if s.worktreeRoot}<button class="small" onclick={() => { s!.worktreeRoot = ""; save(); }}>{tr("Standaard", "Default")}</button>{/if}</span>
    </div>
    <div class="row">
      <span>{tr("Prefix voor branches", "Branch prefix")}</span>
      <span class="inline">
        <input class="prefix" placeholder="nook" aria-label={tr("Prefix voor branches", "Branch prefix")} value={s.branchPrefix ?? "nook"}
          onchange={(e) => { s!.branchPrefix = normalizedPrefix(e.currentTarget.value); e.currentTarget.value = s!.branchPrefix; save(); }} />
        <span class="example">{tr("bijv. {prefix}/fix-login-3fa2", "e.g. {prefix}/fix-login-3fa2", { prefix: normalizedPrefix(s.branchPrefix ?? "nook") })}</span>
      </span>
    </div>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else if s && part === "openIn"}
  <!-- Editor & browser (part openIn): where a session's folder opens. Nook's browser has no settings of its own here yet. -->
  <h3>{tr("Openen in", "Open in")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Editor", "Editor")}</span>
      <select bind:value={s.editor} onchange={save}>
        <option value="">{tr("Verkenner", "File Explorer")}</option>
        {#each editors as e (e.id)}<option value={e.id}>{e.name}</option>{/each}
        {#if s.editor && !editors.some((e) => e.id === s!.editor)}<option value={s.editor}>{s.editor}</option>{/if}
      </select>
    </label>
  </div>
{:else if s && part === "bridge"}
  <!-- Workspace for agents (`bridge`, on Automation): Nook's terminal, browser and pull requests for agents. -->
  <h3>{tr("Werkruimte voor agents", "Workspace for agents")}</h3>
  <p class="section-info">{tr("Sessies die Nook start krijgen dit vanzelf: de agent kan een devserver draaien, een pagina in Nooks browser controleren en een pull request voorstellen. Riskante commando's en elke pull request vragen eerst je OK. De knoppen geven Claude Code, Codex of Gemini CLI die je zelf start hetzelfde.", "Sessions Nook starts get this by themselves: the agent can run a dev server, check a page in Nook's browser and propose a pull request. Risky commands and every pull request ask your OK first. The buttons give Claude Code, Codex or Gemini CLI you start yourself the same.")}</p>
  <div class="group">
    <label class="row"><span>{tr("Agents mogen de terminal, browser en pull requests van Nook gebruiken", "Agents may use Nook's terminal, browser and pull requests")}</span><input type="checkbox" role="switch" bind:checked={s.agentTools} onchange={save} /></label>
    <div class="row"><span>{tr("Ook voor agents buiten Nook", "Also for agents outside Nook")}</span>
      <span class="inline">
        {#each ["claude", "codex", "gemini"] as p (p)}
          <button class="agent small" disabled={!s.agentTools} title={tr("Draait het koppelcommando zichtbaar in een terminal van Nook", "Runs the link command visibly in a Nook terminal")} onclick={() => link(p as RunProvider)}><AgentMark agent={workspace.provider(p)?.name ?? p} size={12} />{workspace.provider(p)?.name ?? p}</button>
        {/each}
      </span>
    </div>
    {#if linked}<p class="note ok">{linked}</p>{/if}
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else if !s}
  <p class="faint">{tr("Laden…", "Loading…")}</p>
{/if}

<style>
  .inline { display: flex; gap: var(--space-8); align-items: center; }
  .path { font: var(--text-code); color: var(--text2); }
  .model { width: 220px; }
  .prefix { width: 160px; }
  .stacked textarea, .stacked input { width: 100%; resize: vertical; font: var(--text-body); }
  .example { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .agent-name { display: inline-flex; align-items: center; gap: var(--space-6); }
  .agent { display: inline-flex; align-items: center; gap: var(--space-4); }
  .ok { color: var(--mint) !important; }
  .err { color: var(--coral); font: var(--text-detail); }
</style>
