<script lang="ts">
  // Settings › Projects & pull requests › Pull requests (`WatchedPullRequestsSection` on the Mac): a prompt to connect
  // GitHub when none is linked yet, followed by watched organizations ("acme") and repositories ("acme/web") whose
  // pull requests show under Agents › Pull requests alongside yours.
  import { api } from "../../lib/api";
  import { connectorsApi, connectorEvents, type Overview } from "../../lib/connectors";
  import { tr } from "../../lib/i18n.svelte";
  import { pullsApi } from "../../lib/pulls";
  import { pullRequests } from "../../lib/pulls.svelte";
  import { nook } from "../../lib/state.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  const LIMIT = 20;
  let overview = $state<Overview | null>(null);
  let adding = $state(false);
  let text = $state("");
  let error = $state<string | null>(null);
  let field = $state<HTMLInputElement | null>(null);

  $effect(() => {
    const load = () => connectorsApi.overview().then((o) => (overview = o)).catch(() => {});
    load();
    const un = connectorEvents.onChanged(load);
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
      <button class="small" title={tr("Niet meer volgen", "Stop watching")} onclick={() => remove(entry)}>{tr("Niet meer volgen", "Stop watching")}</button>
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
