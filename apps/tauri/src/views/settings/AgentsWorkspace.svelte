<script lang="ts">
  // Instellingen › Agents › Werkruimte (`SettingsBlocks` op de Mac): wat "Nieuwe sessie" voorstelt, het gedrag van
  // sessies die Nook draait, en de werkruimte voor agents (terminal, browser en pull requests via de brug).
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { agents } from "../../lib/agents.svelte";
  import { permissionLabels, toolsApi, workspaceApi, type PermissionPolicy, type RunProvider, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";

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
      linked = `Het commando draait in een terminal van Nook (Agents › Alle terminals).`;
      agents.select("terminals");
    } catch (e) {
      error = String(e);
    }
  }

  const providers = $derived(workspace.providers.filter((p) => p.supported));
  const policies = $derived<PermissionPolicy[]>(workspace.provider(s?.defaultProvider ?? "claude")?.capabilities.policies ?? ["acceptEdits"]);
</script>

{#if s}
  <h3>Werkruimte</h3>
  <div class="group">
    <label class="row"><span>Standaard-agent</span>
      <select bind:value={s.defaultProvider} onchange={save}>{#each providers as p (p.provider)}<option value={p.provider}>{p.name}</option>{/each}</select>
    </label>
    <label class="row"><span>Model voor {workspace.provider(s.defaultProvider)?.name ?? s.defaultProvider}</span>
      <input placeholder="standaard" value={s.defaultModels[s.defaultProvider] ?? ""} onchange={(e) => { s!.defaultModels[s!.defaultProvider] = (e.target as HTMLInputElement).value.trim(); save(); }} />
    </label>
    <label class="row"><span>Standaardmodus</span>
      <select bind:value={s.defaultMode} onchange={save}><option value="agent">Agent</option><option value="plan">Plan</option></select>
    </label>
    <label class="row"><span>Standaardrechten</span>
      <select bind:value={s.defaultPermission} onchange={save}>{#each policies as p (p)}<option value={p}>{permissionLabels[p]}</option>{/each}</select>
    </label>
    <label class="row"><span>Standaard-isolatie</span>
      <select bind:value={s.defaultIsolation} onchange={save}><option value="worktree">Nieuwe worktree</option><option value="folder">Huidige map</option></select>
    </label>
    <div class="row"><span>Map voor worktrees</span>
      <span class="inline"><span class="mono faint">{s.worktreeRoot || "~/.nook/worktrees"}</span><button class="ghost" onclick={chooseRoot}>Wijzig…</button>
        {#if s.worktreeRoot}<button class="ghost" onclick={() => { s!.worktreeRoot = ""; save(); }}>Standaard</button>{/if}</span>
    </div>
    <label class="row"><span>Automatisch archiveren na</span>
      <select bind:value={s.autoArchiveDays} onchange={save}>
        <option value={0}>Nooit</option><option value={1}>1 dag</option><option value={7}>7 dagen</option><option value={30}>30 dagen</option><option value={90}>90 dagen</option>
      </select>
    </label>
    <label class="check"><input type="checkbox" bind:checked={s.showCost} onchange={save} /> Kosten tonen die agents zelf melden</label>
    <label class="check"><input type="checkbox" bind:checked={s.autoResumeLimited} onchange={save} /> Na een gebruikslimiet vanzelf verdergaan zodra die vrij is</label>
    <label class="check"><input type="checkbox" bind:checked={s.steerByDefault} onchange={save} /> Een bericht tijdens een beurt stuurt de agent bij (Ctrl+Enter zet het in de wachtrij)</label>
    <p class="faint note">Wat 'Nieuwe sessie' voorstelt. Kies je daar iets anders, dan onthoudt Nook dat. Rechten die een agent niet ondersteunt, vallen terug op 'Bewerkingen toestaan'.</p>
  </div>

  <h3>Werkruimte voor agents</h3>
  <div class="group">
    <label class="check"><input type="checkbox" bind:checked={s.agentTools} onchange={save} /> Agents mogen de terminal, browser en pull requests van Nook gebruiken</label>
    <div class="row"><span>Ook voor agents buiten Nook</span>
      <span class="inline">
        {#each ["claude", "codex", "gemini"] as p (p)}
          <button disabled={!s.agentTools} title="Draait het koppelcommando zichtbaar in een terminal van Nook" onclick={() => link(p as RunProvider)}>{workspace.provider(p)?.name ?? p}</button>
        {/each}
      </span>
    </div>
    {#if linked}<p class="ok">{linked}</p>{/if}
    <p class="faint note">
      Sessies die Nook start krijgen dit vanzelf. Een agent kan dan een dev-server in een zichtbare terminal starten, een
      pagina openen en controleren in de browser van Nook, en een pull request voorstellen. Lezen gaat direct; een
      commando dat niet duidelijk onschuldig is en elk pull request vragen eerst jouw OK, en gevaarlijke commando's
      weigert Nook altijd. In Plan-modus mag een agent alleen kijken. Met de knoppen koppel je hetzelfde aan Claude Code,
      Codex of Gemini CLI die je zelf in een terminal start; je ziet het commando terwijl het draait.
    </p>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
{:else}
  <p class="faint">Laden…</p>
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
