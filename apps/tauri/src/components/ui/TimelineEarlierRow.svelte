<script lang="ts">
  // "Show earlier messages" between two hairlines at the top of a long conversation that opened with only its latest
  // turns (`TimelineEarlierRow`).
  import { tr } from "../../lib/i18n.svelte";
  import Spinner from "./Spinner.svelte";
  let { onshow, loading = false }: { onshow: () => void; loading?: boolean } = $props();
</script>

<div class="earlier">
  <button class="ghost" disabled={loading} onclick={onshow}>
    {#if loading}<Spinner size={11} />{/if}{tr("Toon eerdere berichten", "Show earlier messages")}
  </button>
</div>

<style>
  .earlier { display: flex; align-items: center; gap: var(--space-8); margin: var(--space-8) 0; }
  .earlier::before, .earlier::after { content: ""; flex: 1; height: 1px; background: var(--hairline); }
  button { display: inline-flex; align-items: center; gap: var(--space-6); font: var(--text-detail); color: var(--text2); }
</style>
