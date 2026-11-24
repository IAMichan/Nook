<script lang="ts">
  // Watched pull requests (`WatchedPullRequestsSection` on the Mac, Settings › Projects & pull requests › Pull requests): organizations ("acme") and repositories ("acme/web",
  // or a GitHub link) whose pull requests show under Agents › Pull requests as well. Nook searches them with every
  // connected GitHub account; the core checks and normalizes what is typed.
  import { tr } from "../../lib/i18n.svelte";
  import { pullsApi } from "../../lib/pulls";
  import { pullRequests } from "../../lib/pulls.svelte";
  import { nook } from "../../lib/state.svelte";

  const LIMIT = 20;
  let text = $state("");
  let error = $state<string | null>(null);
  const entries = $derived(nook.settings?.watchedPullRequests ?? []);

  async function changed(list: string[]) {
    if (nook.settings) nook.settings = { ...nook.settings, watchedPullRequests: list };
    pullRequests.markStale();
  }

  async function add() {
    error = null;
    try {
      await changed(await pullsApi.watchAdd(text));
      text = "";
    } catch (e) {
      error = String(e);
    }
  }

  async function remove(entry: string) {
    await changed(await pullsApi.watchRemove(entry));
  }
</script>

<h3>{tr("Gevolgde pull requests", "Watched pull requests")}</h3>
<p class="section-info">{tr("Hun open pull requests staan naast die van jou bij Agents, gezocht met elk gekoppeld GitHub-account.", "Their open pull requests show next to yours under Agents, searched with every connected GitHub account.")}</p>
<div class="group">
  {#each entries as entry (entry)}
    <div class="row">
      <span class="text"><span>{entry}</span><span class="small">{entry.includes("/") ? tr("Repository", "Repository") : tr("Organisatie", "Organization")}</span></span>
      <button title={tr("Niet meer volgen", "Stop watching")} onclick={() => remove(entry)}>{tr("Niet meer volgen", "Stop watching")}</button>
    </div>
  {/each}
  <div class="row add">
    <input placeholder={tr("organisatie of eigenaar/repository", "organization or owner/repository")} aria-label={tr("Toevoegen", "Add")} bind:value={text} oninput={() => (error = null)} onkeydown={(e) => e.key === "Enter" && text.trim() && add()} />
    <button onclick={add} disabled={!text.trim() || entries.length >= LIMIT}>{tr("Organisatie volgen", "Watch organization")}</button>
  </div>
  {#if error}<p class="note err">{error}</p>{:else if entries.length >= LIMIT}<p class="note">{tr("Je kunt tot {n} organisaties en repositories volgen.", "You can watch up to {n} organizations and repositories.", { n: LIMIT })}</p>{/if}
</div>

<style>
  .text { display: flex; flex-direction: column; gap: var(--space-2); min-width: 0; }
  .small { font: var(--text-detail); color: var(--text2); }
  .add { flex-wrap: nowrap; }
  .add input { flex: 1; min-width: 0; }
</style>
