<script lang="ts">
  // The big choices on top of a dropdown as tinted tiles in a grid of three (`DropdownTileGrid`, `DropdownTile`), with an
  // optional quiet tip line at its foot (`DropdownNote`: "Or drop files on the chat").
  import Ico from "./Ico.svelte";
  export interface DropdownTileItem { id: string; icon: string; label: string; tint?: string; disabled?: boolean; onselect: () => void }
  let { tiles, note }: { tiles: DropdownTileItem[]; note?: string } = $props();
</script>

<div class="tiles">
  {#each tiles as t (t.id)}
    <button class="tile" style:--tint={t.tint ?? "var(--text2)"} disabled={t.disabled} onclick={t.onselect}>
      <span class="mark"><Ico name={t.icon} size={16} stroke={2} /></span>
      <span class="label">{t.label}</span>
    </button>
  {/each}
</div>
{#if note}<p class="note">{note}</p>{/if}

<style>
  .tiles { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: var(--space-6); padding: var(--space-4); }
  .tile { display: flex; flex-direction: column; align-items: center; gap: var(--space-6); padding: var(--space-12) var(--space-4); background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-card); }
  .tile:hover:not(:disabled) { background: var(--row-hover); }
  .mark { display: inline-flex; align-items: center; justify-content: center; width: 30px; height: 30px; border-radius: var(--radius-control); color: var(--tint); background: color-mix(in srgb, var(--tint) 16%, transparent); }
  .label { font: var(--text-label); color: var(--paper); text-align: center; }
  .note { margin: var(--space-4) var(--space-8) var(--space-6); font: var(--text-detail); color: var(--text3); }
</style>
