<script lang="ts">
  // One chip in a row of filters (`NookFilterChip`): quiet at rest, filled with the accent when chosen, with an
  // optional count and an optional `mark` (the state of what it stands for, shown while it runs or when it failed).
  import type { Snippet } from "svelte";
  let { label, selected = false, count, mark, onclick }: {
    label: string; selected?: boolean; count?: number; mark?: Snippet; onclick: () => void;
  } = $props();
</script>

<button class="chip" class:selected aria-pressed={selected} {onclick}>
  {#if mark}<span class="mark">{@render mark()}</span>{/if}
  <span>{label}</span>
  {#if count !== undefined}<span class="count">{count}</span>{/if}
</button>

<style>
  .chip { display: inline-flex; align-items: center; gap: var(--space-4); padding: var(--space-2) var(--space-8); border-radius: var(--radius-control); background: transparent; border: 1px solid var(--line2); color: var(--text2); font: var(--text-control); white-space: nowrap; }
  .chip:hover:not(:disabled) { color: var(--paper); background: var(--row-hover); }
  .chip.selected, .chip.selected:hover:not(:disabled) { background: var(--iris); border-color: transparent; color: var(--on-iris); }
  .count { opacity: 0.7; font-variant-numeric: tabular-nums; }
  .mark { display: inline-flex; }
</style>
