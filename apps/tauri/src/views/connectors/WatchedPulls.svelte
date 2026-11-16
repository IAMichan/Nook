<script lang="ts">
  // Watched pull requests (`WatchedPullRequestsBlock` on the Mac): organizations ("acme") and repositories ("acme/web",
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
<div class="group">
  {#each entries as entry (entry)}
    <div class="row">
      <span class="text"><span>{entry}</span><span class="faint small">{entry.includes("/") ? tr("Repository", "Repository") : tr("Organisatie", "Organization")}</span></span>
      <button class="ghost danger" title={tr("Niet meer volgen", "Stop watching")} onclick={() => remove(entry)}>{tr("Niet meer volgen", "Stop watching")}</button>
    </div>
  {/each}
  <div class="row">
    <span class="inline wide">
      <input placeholder={tr("organisatie of eigenaar/repository", "organization or owner/repository")} aria-label={tr("Toevoegen", "Add")} bind:value={text} oninput={() => (error = null)} onkeydown={(e) => e.key === "Enter" && text.trim() && add()} />
      <button onclick={add} disabled={!text.trim() || entries.length >= LIMIT}>{tr("Toevoegen", "Add")}</button>
    </span>
  </div>
  {#if error}<p class="err">{error}</p>{:else if entries.length >= LIMIT}<p class="faint small">{tr("Je kunt tot {n} organisaties en repositories volgen.", "You can watch up to {n} organizations and repositories.", { n: LIMIT })}</p>{/if}
</div>
<p class="faint small">{tr("Open pull requests in deze organisaties en repositories staan ook onder Agents › Pull requests, naast die van jou en die op jouw review wachten. Nook doorzoekt ze met elk gekoppeld GitHub-account.", "Open pull requests in these organizations and repositories also show under Agents › Pull requests, next to yours and the ones waiting for your review. Nook searches them with every connected GitHub account.")}</p>

<style>
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .small { font-size: 11px; }
  .wide { width: 100%; }
  .wide input { flex: 1; }
</style>
