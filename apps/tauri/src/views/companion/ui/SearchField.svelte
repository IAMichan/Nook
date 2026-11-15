<script lang="ts">
  // The search field (`NookSearchField`).
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { value = $bindable(""), placeholder }: { value: string; placeholder: string } = $props();
</script>

<label class="search">
  <Ico name="search" size={13} stroke={2.2} />
  <input bind:value {placeholder} aria-label={placeholder} autocapitalize="off" autocomplete="off" />
  {#if value}<button class="clear" aria-label={tr("Wis", "Clear")} onclick={() => (value = "")}><Ico name="circle-x" size={13} /></button>{/if}
</label>

<style>
  .search { display: flex; align-items: center; gap: 6px; padding: 0 2px 0 8px; min-height: 38px; background: var(--field); border-radius: 8px; color: var(--text3); }
  input { flex: 1; min-width: 0; }
  .clear { width: 28px; height: 28px; display: inline-flex; align-items: center; justify-content: center; color: var(--text3); }
</style>
