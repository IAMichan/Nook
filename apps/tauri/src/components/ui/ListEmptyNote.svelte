<script lang="ts">
  // The one line a list shows when it is empty or nothing matches (`ListEmptyNote`); a whole empty page is an
  // `EmptyState`.
  let { text }: { text: string } = $props();
</script>

<p class="note">{text}</p>

<style>
  .note { margin: 0; padding: var(--space-12) var(--space-8); font: var(--text-detail); color: var(--text3); }
</style>
