<script lang="ts">
  // A folded group on a Settings page (`SettingsFold`): one card whose head is a chevron, a name and on the right what
  // is inside in short; open, its rows follow in the same card.
  import type { Snippet } from "svelte";
  import DisclosureChevron from "../../components/ui/DisclosureChevron.svelte";
  import { settingsHighlight } from "../../lib/settings-search.svelte";
  // `keys`: the names of the settings inside, so a search for one of them opens the fold before the page scrolls there.
  let { title, summary = "", keys = [], open = $bindable(false), children }: { title: string; summary?: string; keys?: string[]; open?: boolean; children: Snippet } = $props();
  $effect(() => {
    const wanted = settingsHighlight.title;
    if (wanted && (wanted === title || keys.includes(wanted))) open = true;
  });
</script>

<div class="group fold">
  <button class="fold-head" aria-expanded={open} onclick={() => (open = !open)}>
    <DisclosureChevron {open} />
    <span class="name">{title}</span>
    {#if summary}<span class="summary">{summary}</span>{/if}
  </button>
  {#if open}<div class="fold-body">{@render children()}</div>{/if}
</div>

<style>
  .fold-head { display: flex; align-items: center; gap: var(--space-12); width: 100%; min-height: 0; padding: var(--space-12) 0; border: none; border-radius: 0; background: none; color: var(--paper); font: var(--text-body); text-align: left; }
  .fold-head:hover:not(:disabled) { background: none; }
  .name { flex: 1; min-width: 0; }
  .summary { color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .fold-body { border-top: 1px solid var(--separator); }
</style>
