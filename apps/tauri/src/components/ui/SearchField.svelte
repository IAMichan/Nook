<script lang="ts">
  // The search field (`NookSearchField`).
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { value = $bindable(""), placeholder }: { value: string; placeholder: string } = $props();
</script>

<label class="search">
  <Ico name="search" size={13} stroke={2.2} />
  <input bind:value {placeholder} aria-label={placeholder} autocapitalize="off" autocomplete="off" />
  {#if value}<button class="clear" aria-label={tr("Wis", "Clear")} onclick={() => (value = "")}><Ico name="circle-x" size={13} /></button>{/if}
</label>

<style>
  .search { display: flex; align-items: center; gap: var(--space-6); padding: 0 2px 0 var(--space-8); min-height: 30px; background: var(--field); border: 1px solid var(--line2); border-radius: var(--radius-control); color: var(--text3); }
  input { flex: 1; min-width: 0; padding: 0; border: none !important; background: none; box-shadow: none !important; }
  .clear { width: 24px; height: 24px; padding: 0; border: none; background: none; display: inline-flex; align-items: center; justify-content: center; color: var(--text3); }
  :global(.phone) .search { min-height: 38px; border: none; border-radius: 8px; }
  :global(.phone) .clear { width: 28px; height: 28px; }
</style>
