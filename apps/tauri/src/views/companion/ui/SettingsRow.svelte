<script lang="ts">
  // A row of Settings (`SettingsRow`): an icon on a soft tile, a title and a detail, and what goes on the right.
  import type { Snippet } from "svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  let { icon, title, detail, tint = "var(--text2)", destructive = false, onclick, trailing }: {
    icon: string; title: string; detail?: string; tint?: string; destructive?: boolean; onclick?: () => void; trailing?: Snippet;
  } = $props();
  const color = $derived(destructive ? "var(--coral)" : tint);
</script>

{#snippet content()}
  <span class="tile" style:color={color} style:background="color-mix(in srgb, {color} 12%, transparent)"><Ico name={icon} size={14} /></span>
  <span class="text"><span class="title" class:destructive>{title}</span>{#if detail}<span class="detail">{detail}</span>{/if}</span>
  {#if trailing}{@render trailing()}{:else if onclick && !destructive}<span class="chev"><Ico name="chevron-right" size={12} stroke={2.6} /></span>{/if}
{/snippet}

{#if onclick}
  <button class="row" {onclick}>{@render content()}</button>
{:else}
  <div class="row">{@render content()}</div>
{/if}

<style>
  .row { width: 100%; display: flex; align-items: center; gap: 8px; padding: 12px 16px; min-height: 52px; text-align: left; box-sizing: border-box; }
  button.row:active { background: var(--row-hover) !important; }
  .tile { width: 28px; height: 28px; border-radius: 7.8px; display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .title { font: var(--pt-body); color: var(--paper); }
  .title.destructive { color: var(--coral); }
  .detail { font: var(--pt-detail); color: var(--text3); }
  .chev { color: var(--text3); display: inline-flex; }
</style>
