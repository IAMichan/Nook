<script lang="ts">
  // How many wait for you (`NookCountBadge`): amber numerals on a faint amber wash, on a tab, a list title or a chat's
  // row; nothing at zero.
  let { count, label }: { count: number; label?: string } = $props();
</script>

{#if count > 0}<span class="badge" aria-label={label}>{count > 99 ? "99+" : count}</span>{/if}

<style>
  .badge { display: inline-flex; align-items: center; justify-content: center; min-width: 16px; height: 16px; padding: 0 var(--space-4); border-radius: var(--radius-chip); background: color-mix(in srgb, var(--amber) 14%, transparent); color: var(--amber); font: var(--text-caption); font-weight: 600; line-height: 16px; box-sizing: border-box; flex: none; font-variant-numeric: tabular-nums; }
</style>
