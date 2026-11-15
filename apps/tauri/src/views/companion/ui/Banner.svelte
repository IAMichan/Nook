<script lang="ts">
  // A banner (`Banner`): an icon in its color and words on a card.
  import type { Snippet } from "svelte";
  import Ico from "./Ico.svelte";
  let { icon, tint = "var(--amber)", children, onclick }: { icon: string; tint?: string; children: Snippet; onclick?: () => void } = $props();
</script>

{#if onclick}
  <button class="banner press" {onclick}><span style:color={tint}><Ico name={icon} size={14} stroke={2.2} /></span><span class="text">{@render children()}</span></button>
{:else}
  <div class="banner"><span style:color={tint}><Ico name={icon} size={14} stroke={2.2} /></span><span class="text">{@render children()}</span></div>
{/if}

<style>
  .banner { display: flex; align-items: baseline; gap: 8px; padding: 10px 12px; background: var(--surface); border: 1px solid var(--line2); border-radius: 12px; text-align: left; width: 100%; box-sizing: border-box; }
  .banner > span:first-child { position: relative; top: 2px; }
  .text { font: var(--pt-detail); color: var(--text-strong); flex: 1; }
</style>
