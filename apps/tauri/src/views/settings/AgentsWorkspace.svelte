<script lang="ts">
  // Instellingen › Agents › Werkruimte (`SettingsBlocks` op de Mac): wat "Nieuwe sessie" voorstelt, het gedrag van
  // sessies die Nook draait, en de werkruimte voor agents (terminal, browser en pull requests via de brug).
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agents } from "../../lib/agents.svelte";
  import { permissionLabels, toolsApi, workspaceApi, type PermissionPolicy, type RunProvider, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import { tr } from "../../lib/i18n.svelte";

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

{#if s}
  <h3>{tr("Werkruimte", "Workspace")}</h3>
  <div class="group">
    <label class="row"><span>{tr("Standaard-agent", "Default agent")}</span>
      <select bind:value={s.defaultProvider} onchange={save}>{#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}</select>
    </label>
    <label class="row"><span>{tr("Model voor {agent}", "Model for {agent}", { agent: workspace.provider(s.defaultProvider)?.name ?? s.defaultProvider })}</span>
      <input placeholder={tr("standaard", "default")} value={s.defaultModels[s.defaultProvider] ?? ""} onchange={(e) => { s!.defaultModels[s!.defaultProvider] = (e.target as HTMLInputElement).value.trim(); save(); }} />
    </label>
    <label class="row"><span>{tr("Standaardmodus", "Default mode")}</span>
      <select bind:value={s.defaultMode} onchange={save}><option value="agent">Agent</option><option value="plan">Plan</option></select>
    </label>
    <label class="row"><span>{tr("Standaardrechten", "Default permissions")}</span>
      <select bind:value={s.defaultPermission} onchange={save}>{#each policies as p (p)}<option value={p}>{permissionLabels[p]}</option>{/each}</select>
    </label>
    <label class="row"><span>{tr("Standaard-isolatie", "Default isolation")}</span>
      <select bind:value={s.defaultIsolation} onchange={save}><option value="worktree">{tr("Nieuwe worktree", "New worktree")}</option><option value="folder">{tr("Huidige map", "Current folder")}</option></select>
    </label>
    <div class="row"><span>{tr("Map voor worktrees", "Folder for worktrees")}</span>
      <span class="inline"><span class="mono faint">{s.worktreeRoot || "~/.nook/worktrees"}</span><button class="ghost" onclick={chooseRoot}>{tr("Wijzig…", "Change…")}</button>
        {#if s.worktreeRoot}<button class="ghost" onclick={() => { s!.worktreeRoot = ""; save(); }}>{tr("Standaard", "Default")}</button>{/if}</span>
    </div>
    <label class="row"><span>{tr("Automatisch archiveren na", "Archive automatically after")}</span>
      <select bind:value={s.autoArchiveDays} onchange={save}>
        <option value={0}>{tr("Nooit", "Never")}</option><option value={1}>{tr("1 dag", "1 day")}</option>{#each [7, 30, 90] as n (n)}<option value={n}>{tr("{n} dagen", "{n} days", { n })}</option>{/each}
      </select>
    </label>
    <label class="check"><input type="checkbox" bind:checked={s.showCost} onchange={save} /> {tr("Kosten tonen die agents zelf melden", "Show the costs agents report themselves")}</label>
    <label class="check"><input type="checkbox" bind:checked={s.autoResumeLimited} onchange={save} /> {tr("Na een gebruikslimiet vanzelf verdergaan zodra die vrij is", "After a usage limit, carry on by itself once it resets")}</label>
    <label class="check"><input type="checkbox" bind:checked={s.steerByDefault} onchange={save} /> {tr("Een bericht tijdens een beurt stuurt de agent bij (Ctrl+Enter zet het in de wachtrij)", "A message during a turn steers the agent (Ctrl+Enter queues it)")}</label>
    <p class="faint note">{tr("Wat 'Nieuwe sessie' voorstelt. Kies je daar iets anders, dan onthoudt Nook dat. Rechten die een agent niet ondersteunt, vallen terug op 'Bewerkingen toestaan'.", "What 'New session' suggests. If you pick something else there, Nook remembers it. Permissions an agent doesn't support fall back to 'Allow edits'.")}</p>
  </div>

  <h3>{tr("Werkruimte voor agents", "Workspace for agents")}</h3>
  <div class="group">
    <label class="check"><input type="checkbox" bind:checked={s.agentTools} onchange={save} /> {tr("Agents mogen de terminal, browser en pull requests van Nook gebruiken", "Agents may use Nook's terminal, browser and pull requests")}</label>
    <div class="row"><span>{tr("Ook voor agents buiten Nook", "Also for agents outside Nook")}</span>
      <span class="inline">
        {#each ["claude", "codex", "gemini"] as p (p)}
          <button disabled={!s.agentTools} title={tr("Draait het koppelcommando zichtbaar in een terminal van Nook", "Runs the link command visibly in a Nook terminal")} onclick={() => link(p as RunProvider)}>{workspace.provider(p)?.name ?? p}</button>
        {/each}
      </span>
    </div>
    {#if linked}<p class="ok">{linked}</p>{/if}
    <p class="faint note">
      {tr(
        "Sessies die Nook start krijgen dit vanzelf. Een agent kan dan een dev-server in een zichtbare terminal starten, een pagina openen en controleren in de browser van Nook, en een pull request voorstellen. Lezen gaat direct; een commando dat niet duidelijk onschuldig is en elk pull request vragen eerst jouw OK, en gevaarlijke commando's weigert Nook altijd. In Plan-modus mag een agent alleen kijken. Met de knoppen koppel je hetzelfde aan Claude Code, Codex of Gemini CLI die je zelf in een terminal start; je ziet het commando terwijl het draait.",
        "Sessions Nook starts get this by themselves. An agent can then start a dev server in a visible terminal, open and check a page in Nook's browser, and propose a pull request. Reading happens right away; a command that isn't clearly harmless and every pull request ask for your OK first, and Nook always refuses dangerous commands. In Plan mode an agent may only look. With the buttons you link the same to Claude Code, Codex or Gemini CLI that you start in a terminal yourself; you see the command while it runs.",
      )}
    </p>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else}
  <p class="faint">{tr("Laden…", "Loading…")}</p>
{/if}

<style>
  .group { display: flex; flex-direction: column; gap: 8px; margin-bottom: 18px; }
  .row { display: flex; justify-content: space-between; align-items: center; gap: 12px; font-size: 13px; }
  .inline { display: flex; gap: 6px; align-items: center; }
  .check { display: flex; gap: 8px; align-items: center; font-size: 13px; }
  .mono { font-family: var(--mono); font-size: 11.5px; }
  .note { font-size: 12px; margin: 0; }
  .ok { color: var(--mint); font-size: 12px; margin: 0; }
  .err { color: var(--coral); font-size: 12px; }
</style>
