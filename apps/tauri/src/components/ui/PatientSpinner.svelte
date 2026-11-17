<script lang="ts">
  // What a pane shows while content of unknown shape loads (`PatientSpinner`): nothing for the first 350 ms, then a
  // small spinner that fades in, so a fast load never flashes. Where the layout is known, use `Skeleton` instead.
  import Spinner from "./Spinner.svelte";
  let { label }: { label?: string } = $props();
  let visible = $state(false);
  $effect(() => {
    const t = setTimeout(() => (visible = true), 350);
    return () => clearTimeout(t);
  });
</script>

<div class="patient" role="status" aria-label={label}>
  {#if visible}<span class="in"><Spinner size={16} /></span>{/if}
</div>

<style>
  .patient { display: flex; align-items: center; justify-content: center; padding: var(--space-24); color: var(--text3); min-height: 16px; }
  .in { display: inline-flex; animation: fade 200ms ease-out; }
  @keyframes fade { from { opacity: 0; } }
</style>
