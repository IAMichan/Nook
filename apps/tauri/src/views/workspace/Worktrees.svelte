<script lang="ts">
  // Alle worktrees van de repositories in de werkruimte (`WorktreesView` op de Mac): de sessie erbij, de wijzigingen,
  // en een terminal of weghalen. Weghalen vraagt eerst bevestiging, en kan niet zolang er een sessie in werkt.
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { isActive, projectName, toolsApi, workspaceApi, type WorktreeRow } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";

  let rows = $state<WorktreeRow[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let confirm = $state<WorktreeRow | null>(null);

  async function load(refresh: boolean) {
    loading = true;
    try {
      rows = await workspaceApi.worktrees(refresh);
    } catch (e) {
      error = String(e);
    }
    loading = false;
  }

  $effect(() => {
    workspace.start();
    load(true);
  });

  const runFor = (row: WorktreeRow) => row.runIds.map((id) => workspace.run(id)).find((r) => !!r);
  const busy = (row: WorktreeRow) => row.runIds.some((id) => {
    const r = workspace.run(id);
    return r ? isActive(r.status) : false;
  });

  async function remove(row: WorktreeRow, force: boolean) {
    confirm = null;
    error = null;
    try {
      await workspaceApi.removeWorktree(row.repoRoot, row.worktree.path, force);
      agents.confirm(tr("Worktree verwijderd", "Worktree removed"));
    } catch (e) {
      error = String(e);
    }
    load(false);
  }

  function openSession(id: string) {
    agents.select(`run:${id}`);
  }
</script>

<div class="worktrees">
  <div class="head">
    <div>
      <strong>{tr("Worktrees", "Worktrees")}</strong>
      <div class="faint small">{tr("Elke worktree is een eigen map met een eigen branch, naast je gewone checkout.", "Each worktree is its own folder with its own branch, next to your regular checkout.")}</div>
    </div>
    <span class="spacer"></span>
    <button class="ghost" disabled={loading} onclick={() => load(true)}>{loading ? tr("Bezig…", "Busy…") : tr("Ververs", "Refresh")}</button>
  </div>
  {#if error}<p class="err">{error}</p>{/if}
  {#if workspace.overview && !workspace.overview.gitAvailable}
    <div class="empty"><p>{tr("Git ontbreekt", "Git is missing")}</p><p class="faint">{tr("Git is niet gevonden. Installeer Git en start Nook opnieuw.", "Git wasn't found. Install Git and restart Nook.")}</p></div>
  {:else if !rows.length && !loading}
    <div class="empty">
      <p>{tr("Nog geen worktrees", "No worktrees yet")}</p>
      <p class="faint">{tr("Start een sessie met 'Nieuwe worktree' om agents naast elkaar te laten werken zonder dat ze elkaars bestanden raken.", "Start a session with 'New worktree' to let agents work side by side without touching each other's files.")}</p>
    </div>
  {:else}
    <div class="table">
      <div class="row header faint"><span>{tr("Worktree", "Worktree")}</span><span>{tr("Branch", "Branch")}</span><span>{tr("Sessie", "Session")}</span><span>{tr("Wijzigingen", "Changes")}</span><span></span></div>
      {#each rows as row (row.worktree.path)}
        {@const run = runFor(row)}
        <div class="row">
          <span class="cell"><span>{projectName(row.worktree.path)}</span><span class="mono faint">{row.worktree.path}</span></span>
          <span class="cell"><span class="mono">{row.worktree.branch ?? tr("geen branch", "no branch")}</span>{#if row.baseBranch}<span class="mono faint">← {row.baseBranch}</span>{/if}</span>
          <span class="cell">
            {#if run}
              <button class="link" title={tr("Open de sessie", "Open the session")} onclick={() => openSession(run.id)}>{run.title}</button>
            {:else}
              <span class="faint">{row.worktree.isMain ? tr("hoofdmap", "main folder") : tr("geen sessie", "no session")}</span>
            {/if}
          </span>
          <span class="cell">
            <span>{row.changedFiles === null ? tr("niet beschikbaar", "not available") : row.changedFiles === 0 ? tr("Geen wijzigingen", "No changes") : tr("{n} bestanden", "{n} files", { n: row.changedFiles })}</span>
            {#if row.ahead !== null && row.behind !== null}<span class="faint">{tr("{ahead} voor · {behind} achter", "{ahead} ahead · {behind} behind", { ahead: row.ahead, behind: row.behind })}</span>{/if}
          </span>
          <span class="actions">
            <button class="ghost" title={tr("Open terminal", "Open terminal")} onclick={() => { toolsApi.openTerminal(row.worktree.path); agents.select("terminals"); }}>›_</button>
            {#if !row.worktree.isMain}
              <button class="ghost danger" title={busy(row) ? tr("Kan niet terwijl de agent werkt.", "Can't while the agent is working.") : tr("Verwijder worktree", "Remove worktree")} disabled={busy(row) || row.worktree.locked}
                onclick={() => (confirm = row)}>🗑</button>
            {/if}
          </span>
        </div>
      {/each}
    </div>
  {/if}
  {#if confirm}
    <div class="confirm">
      <div class="ctext">
        <strong>{tr("Worktree verwijderen?", "Remove worktree?")}</strong>
        <span class="faint">
          {(confirm.changedFiles ?? 0) > 0
            ? tr("Er staan {n} niet-gecommitte wijzigingen in. Die gaan verloren als je doorgaat. De branch en zijn commits blijven bestaan.", "It has {n} uncommitted changes. They are lost if you continue. The branch and its commits stay.", { n: confirm.changedFiles ?? 0 })
            : tr("De map verdwijnt. De branch en zijn commits blijven in de repository.", "The folder goes away. The branch and its commits stay in the repository.")}
        </span>
      </div>
      <button class="ghost" onclick={() => (confirm = null)}>{tr("Annuleer", "Cancel")}</button>
      {#if (confirm.changedFiles ?? 0) > 0}
        <button class="primary" onclick={() => remove(confirm!, true)}>{tr("Verwijder met wijzigingen", "Remove with changes")}</button>
      {:else}
        <button class="primary" onclick={() => remove(confirm!, false)}>{tr("Verwijder worktree", "Remove worktree")}</button>
      {/if}
    </div>
  {/if}
</div>

<style>
  .worktrees { display: flex; flex-direction: column; gap: 10px; height: 100%; min-height: 0; overflow-y: auto; }
  .head { display: flex; align-items: center; gap: 8px; }
  .spacer { flex: 1; }
  .small { font-size: 12px; }
  .table { display: flex; flex-direction: column; gap: 2px; }
  .row { display: grid; grid-template-columns: 2fr 1.4fr 1.4fr 1fr 80px; gap: 10px; padding: 8px; border-radius: 9px; align-items: center; font-size: 12.5px; }
  .row:not(.header):hover { background: var(--graphite); }
  .row.header { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .cell { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .cell > * { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .mono { font-family: var(--mono); font-size: 11px; }
  .link { background: none; border: none; padding: 0; text-align: left; color: var(--paper); text-decoration: underline dotted; }
  .actions { display: flex; gap: 2px; justify-content: flex-end; }
  .confirm { display: flex; gap: 8px; align-items: center; padding: 12px; border-radius: 12px; background: rgba(255, 107, 107, 0.08); }
  .ctext { flex: 1; display: flex; flex-direction: column; gap: 2px; font-size: 12px; }
  .empty { text-align: center; padding: 24px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
