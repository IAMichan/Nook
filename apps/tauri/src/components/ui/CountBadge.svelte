<script lang="ts">
  // How many wait for you (`NookCountBadge`): a small amber count on a tab or a list title; nothing at zero.
  let { count, label }: { count: number; label?: string } = $props();
</script>

{#if count > 0}<span class="badge" aria-label={label}>{count > 99 ? "99+" : count}</span>{/if}

<style>
  .badge { display: inline-flex; align-items: center; justify-content: center; min-width: 16px; height: 16px; padding: 0 var(--space-4); border-radius: 999px; background: var(--amber); color: var(--ink); font: 600 10.5px/16px var(--font); box-sizing: border-box; flex: none; font-variant-numeric: tabular-nums; }
</style>
