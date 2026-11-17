<script lang="ts">
  // A group's name in a list or on a page (`NookSectionLabel`): "Pinned", "For you", lined up with the rows under it.
  import type { Snippet } from "svelte";
  let { text, trailing }: { text: string; trailing?: Snippet } = $props();
</script>

<div class="section-label"><span>{text}</span>{#if trailing}<span class="trailing">{@render trailing()}</span>{/if}</div>

<style>
  .section-label { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-8) var(--space-8) var(--space-4); font: var(--text-caption); color: var(--text3); }
  .trailing { margin-left: auto; display: inline-flex; align-items: center; }
</style>
