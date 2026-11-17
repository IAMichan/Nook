<script lang="ts">
  // One number with its label and a line under it, on a statistics page (`NookStatTile`).
  let { value, label, detail }: { value: string | number; label: string; detail?: string } = $props();
</script>

<div class="tile">
  <span class="label">{label}</span>
  <strong>{value}</strong>
  {#if detail}<span class="detail">{detail}</span>{/if}
</div>

<style>
  .tile { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-12); background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-card); min-width: 0; }
  .label { font: var(--text-label); color: var(--text2); }
  strong { font: var(--text-display); color: var(--paper); font-variant-numeric: tabular-nums; }
  .detail { font: var(--text-detail); color: var(--text3); }
</style>
