<script lang="ts">
  // The chevron of a section that folds (`DisclosureChevron`): pointing right when closed, down when open, turning
  // between them.
  import Ico from "./Ico.svelte";
  let { open, size = 11 }: { open: boolean; size?: number } = $props();
</script>

<span class="chevron" class:open aria-hidden="true"><Ico name="chevron-right" {size} stroke={2.2} /></span>

<style>
  .chevron { display: inline-flex; color: var(--text3); transition: transform 160ms ease; flex: none; }
  .open { transform: rotate(90deg); }
  @media (prefers-reduced-motion: reduce) { .chevron { transition: none; } }
</style>
