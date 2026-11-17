<script lang="ts">
  // Chips that wrap onto as many rows as the width needs (`ChipFlow`): a pull request's labels, a row of filters.
  import type { Snippet } from "svelte";
  let { children, gap = "var(--space-6)" }: { children: Snippet; gap?: string } = $props();
</script>

<div class="flow" style:gap>{@render children()}</div>

<style>
  .flow { display: flex; flex-wrap: wrap; align-items: center; min-width: 0; }
</style>
