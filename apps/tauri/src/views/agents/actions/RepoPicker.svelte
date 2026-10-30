<script lang="ts">
  // The repository picker on the Actions page (`ActionsRepositoryPicker` on the Mac): a button with the chosen
  // repository that opens a list of the ones you pushed to lately and the ones of your pull requests. Typing narrows
  // the list; a full owner/name (or a GitHub link) that is not in it can be picked as well, so any repository you can
  // read is one Enter away. Styled as the Filters dropdown next to the pull request search.
  import { parseRepo, type ActionsRepo } from "../../../lib/actions";
  import { tr } from "../../../lib/i18n.svelte";

  let { repos, value, onpick }: { repos: ActionsRepo[]; value: string | null; onpick: (name: string) => void } = $props();

  let open = $state(false);
  let query = $state("");
  let root = $state<HTMLElement | null>(null);
  let field = $state<HTMLInputElement | null>(null);

  const shown = $derived(repos.filter((r) => !query.trim() || r.name.toLowerCase().includes(query.trim().toLowerCase())));
  // A typed repository that is not in the list yet.
  const typed = $derived.by(() => {
    const name = parseRepo(query);
    return name && !repos.some((r) => r.name.toLowerCase() === name.toLowerCase()) ? name : null;
  });

  function pick(name: string) {
    onpick(name);
    open = false;
    query = "";
  }

  function toggle() {
    open = !open;
    if (open) queueMicrotask(() => field?.focus());
  }

  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") open = false;
    if (e.key !== "Enter") return;
    const name = typed ?? shown[0]?.name;
    if (name) pick(name);
  }

  function outside(e: MouseEvent) {
    if (open && root && !root.contains(e.target as Node)) open = false;
  }
</script>

<svelte:window onclick={outside} />

<div class="menu" bind:this={root}>
  <button class="trigger" aria-expanded={open} title={tr("Kies een repository", "Choose a repository")} onclick={toggle}>
    <span class="name">{value ?? tr("Kies een repository", "Choose a repository")}</span>
    <span class="faint" aria-hidden="true">▾</span>
  </button>
  {#if open}
    <div class="panel" role="dialog" aria-label={tr("Repository", "Repository")}>
      <input bind:this={field} placeholder={tr("Zoek of typ eigenaar/naam", "Search or type owner/name")} bind:value={query} onkeydown={keys} />
      <div class="scroll">
        {#if typed}
          <button class="choice" onclick={() => pick(typed!)}><span class="mark">+</span>{typed}</button>
        {/if}
        {#each shown as repo (repo.name)}
          <button class="choice" class:on={repo.name === value} aria-pressed={repo.name === value} onclick={() => pick(repo.name)}>
            <span class="mark">{repo.name === value ? "✓" : ""}</span><span class="title">{repo.name}</span>
          </button>
        {:else}
          {#if !typed}<span class="faint small">{tr("Geen repository gevonden. Typ eigenaar/naam.", "No repository found. Type owner/name.")}</span>{/if}
        {/each}
      </div>
    </div>
  {/if}
</div>

<style>
  .menu { position: relative; min-width: 0; }
  .trigger { height: 30px; max-width: 100%; padding: 0 10px; display: flex; align-items: center; gap: 6px; color: var(--paper); background: var(--field); font-size: 12.5px; }
  .name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .panel { position: absolute; left: 0; top: 36px; z-index: 20; width: min(340px, calc(100vw - 32px)); display: flex; flex-direction: column; gap: 6px; padding: 6px; background: var(--graphite); border: 1px solid var(--line2); border-radius: 12px; box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5); }
  .panel input { font-size: 12.5px; }
  .scroll { max-height: 280px; overflow-y: auto; display: flex; flex-direction: column; }
  .choice { display: flex; align-items: center; gap: 8px; height: 28px; padding: 0 8px; border: none; background: none; border-radius: 7px; text-align: left; font-size: 12.5px; white-space: nowrap; min-width: 0; }
  .choice:hover, .choice.on { background: var(--smoke); }
  .title { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .mark { width: 12px; text-align: center; color: var(--text3); flex: none; }
  .small { font-size: 12px; padding: 4px 8px; }
</style>
