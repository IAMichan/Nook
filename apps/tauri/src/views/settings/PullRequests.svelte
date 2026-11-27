<script lang="ts">
  import { tip } from "../../components/ui/tip";
  // Settings › Projects & pull requests › Pull requests (`WatchedPullRequestsSection` + `commitStyle` on the Mac):
  // GitHub prompt when unlinked, watched organizations/repositories, commit style and agent-credit switches.
  import { api } from "../../lib/api";
  import { connectorsApi, connectorEvents, type Overview } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import { pullsApi } from "../../lib/pulls";
  import { pullRequests } from "../../lib/pulls.svelte";
  import { nook } from "../../lib/state.svelte";
  import { workspaceApi, type CommitStyle, type WorkspaceSettings } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ForgeHostsSection from "../connectors/ForgeHostsSection.svelte";

  const LIMIT = 20;
  let overview = $state<Overview | null>(null);
  let ws = $state<WorkspaceSettings | null>(null);
  let adding = $state(false);
  let text = $state("");
  let error = $state<string | null>(null);
  let field = $state<HTMLInputElement | null>(null);

  function loadOverview() {
    connectorsApi.overview().then((o) => (overview = o)).catch(() => {});
  }

  $effect(() => {
    loadOverview();
    workspace.start().then(() => {
      ws = workspace.settings ? { ...workspace.settings } : null;
    });
    const un = connectorEvents.onChanged(loadOverview);
    return () => {
      un.then((f) => f());
    };
  });

  const hasGitHub = $derived(
    overview ? overview.connectors.some((c) => c.id === "github" && c.configured) : true,
  );
  const entries = $derived(nook.settings?.watchedPullRequests ?? []);

  function openAdd() {
    adding = true;
    error = null;
    queueMicrotask(() => field?.focus());
  }

  function connectGitHub() {
    localStorage.setItem("settings.section", "connections");
    api.showMain("settings");
  }

  async function changed(list: string[]) {
    if (nook.settings) nook.settings = { ...nook.settings, watchedPullRequests: list };
    pullRequests.markStale();
  }

  async function add() {
    error = null;
    try {
      await changed(await pullsApi.watchAdd(text));
      text = "";
      adding = false;
    } catch (e) {
      error = String(e);
    }
  }

  async function remove(entry: string) {
    await changed(await pullsApi.watchRemove(entry));
  }

  async function saveWs(patch: Partial<WorkspaceSettings>) {
    if (!ws) return;
    ws = { ...ws, ...patch };
    await workspaceApi.saveSettings($state.snapshot(ws));
    await workspace.refresh();
  }
</script>

{#if !hasGitHub}
  <div class="group">
    <div class="row">
      <span>{tr("Koppel eerst GitHub", "Connect GitHub first")}<br /><small>{tr("Pull requests worden gezocht met je GitHub-accounts.", "Pull requests are searched with your GitHub accounts.")}</small></span>
      <button class="small" onclick={connectGitHub}>{tr("Koppelen", "Connect")}</button>
    </div>
  </div>
{/if}

<div class="section-head">
  <h3>{tr("Gevolgde pull requests", "Watched pull requests")}</h3>
  <button class="head-action" disabled={entries.length >= LIMIT} onclick={openAdd}><Ico name="plus" size={14} />{tr("Organisatie volgen", "Watch organization")}</button>
</div>
<p class="section-info">{tr("Hun open pull requests staan naast die van jou bij Agents, gezocht met elk gekoppeld GitHub-account.", "Their open pull requests show next to yours under Agents, searched with every connected GitHub account.")}</p>
<div class="group">
  {#if adding}
    <div class="row add">
      <input bind:this={field} placeholder={tr("organisatie of eigenaar/repository", "organization or owner/repository")} aria-label={tr("Toevoegen", "Add")} bind:value={text}
        oninput={() => (error = null)} onkeydown={(e) => { if (e.key === "Enter" && text.trim()) add(); else if (e.key === "Escape") { adding = false; error = null; } }} />
      <span class="inline">
        <button class="ghost" onclick={() => { adding = false; error = null; }}>{tr("Annuleren", "Cancel")}</button>
        <button class="small" onclick={add} disabled={!text.trim() || entries.length >= LIMIT}>{tr("Toevoegen", "Add")}</button>
      </span>
    </div>
  {/if}
  {#each entries as entry (entry)}
    <div class="row entry">
      <span class="lead-entry">
        <span class="entry-ico"><Ico name={entry.includes("/") ? "book" : "users"} size={14} /></span>
        <span class="text">
          <span>{entry}</span>
          <small>{entry.includes("/") ? tr("Repository", "Repository") : tr("Organisatie", "Organization")}</small>
        </span>
      </span>
      <button class="small" use:tip={tr("Niet meer volgen", "Stop watching")} onclick={() => remove(entry)}>{tr("Niet meer volgen", "Stop watching")}</button>
    </div>
  {:else}
    {#if !adding}
      <div class="empty">
        <strong>{tr("Nog niets gevolgd", "Nothing watched yet")}</strong>
        <span>{tr("Voeg een organisatie (acme) of een repository (acme/web) toe om de open pull requests naast die van jou te zien bij Agents.", "Add an organization (acme) or a repository (acme/web) to see its open pull requests next to yours under Agents.")}</span>
      </div>
    {/if}
  {/each}
  {#if error}<p class="note err">{error}</p>{:else if entries.length >= LIMIT}<p class="note">{tr("Je kunt tot {n} organisaties en repositories volgen.", "You can watch up to {n} organizations and repositories.", { n: LIMIT })}</p>{/if}
</div>

<ForgeHostsSection
  gitlabHosts={overview?.gitlab ?? []}
  forgeHosts={overview?.forges ?? []}
  onchange={loadOverview}
/>

{#if ws}
  <h3>{tr("Commits & pull requests", "Commits & pull requests")}</h3>
  <p class="section-info">{tr("Hoe Nook en coding-agents commits en pull requests schrijven.", "How Nook and coding agents write commits and pull requests.")}</p>
  <div class="group">
    <label class="row">
      <span>{tr("Commitstijl", "Commit style")}</span>
      <select
        value={ws.commitStyle ?? "standard"}
        onchange={(e) => saveWs({ commitStyle: e.currentTarget.value as CommitStyle })}
      >
        <option value="standard">{tr("Standaard", "Standard")}</option>
        <option value="conventional">{tr("Conventional Commits", "Conventional Commits")}</option>
        <option value="repository">{tr("Volg de repository", "Match the repository")}</option>
        <option value="custom">{tr("Eigen instructies", "Custom instructions")}</option>
      </select>
    </label>
    {#if ws.commitStyle === "custom"}
      <div class="row stacked">
        <span>{tr("Instructies voor commits", "Commit instructions")}</span>
        <textarea
          rows="3"
          value={ws.commitInstructions ?? ""}
          placeholder={tr("Bijv. begin het onderwerp met een ticketnummer", "e.g. start the subject with a ticket key")}
          onchange={(e) => saveWs({ commitInstructions: e.currentTarget.value })}
        ></textarea>
      </div>
    {/if}
    <label class="row">
      <span>
        {tr("Geen agent-credits in commits", "No agent credits in commits")}
        <br />
        <small>{tr("Agents die Nook start zetten geen Co-Authored-By of Generated-with-regel in commits en pull requests.", "Agents Nook starts leave AI Co-Authored-By and Generated-with lines out of commits and pull requests.")}</small>
      </span>
      <input
        type="checkbox"
        role="switch"
        checked={!!ws.noAgentCredits}
        onchange={(e) => saveWs({ noAgentCredits: e.currentTarget.checked })}
      />
    </label>
    <label class="row">
      <span>
        {tr("Verwijder agent-credits bij commit of merge", "Strip agent credits on commit or merge")}
        <br />
        <small>{tr("Nook haalt AI-regels weg uit commit- en PR-teksten terwijl menselijke mede-auteurs blijven staan.", "Nook strips AI credit lines from commit and pull request text while keeping human co-authors.")}</small>
      </span>
      <input
        type="checkbox"
        role="switch"
        checked={!!ws.stripAgentCredits}
        onchange={(e) => saveWs({ stripAgentCredits: e.currentTarget.checked })}
      />
    </label>
  </div>
{/if}

<style>
  .entry { flex-wrap: nowrap; }
  .lead-entry { display: flex; align-items: center; gap: var(--space-12); min-width: 0; flex: 1; }
  .entry-ico { display: grid; place-items: center; color: var(--text2); flex: none; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  .add { flex-wrap: nowrap; }
  .add input { flex: 1; min-width: 0; }
  .empty { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16) 0; }
  .empty strong { font: var(--text-emphasis); color: var(--paper); }
  .empty span { font: var(--text-detail); line-height: 1.4; color: var(--text2); }
</style>
