<script lang="ts">
  // The search field (`NookSearchField`).
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { value = $bindable(""), placeholder, autofocus = false, onenter }: {
    value: string;
    placeholder: string;
    autofocus?: boolean;
    onenter?: () => void;
  } = $props();

  function focusIfWanted(node: HTMLInputElement) {
    if (autofocus) node.focus();
  }
</script>

<label class="search">
  <Ico name="search" size={13} stroke={2.2} />
  <input
    use:focusIfWanted
    bind:value
    {placeholder}
    aria-label={placeholder}
    autocapitalize="off"
    autocomplete="off"
    onkeydown={(e) => {
      if (e.key === "Enter" && onenter) {
        e.preventDefault();
        onenter();
      }
    }}
  />
  {#if value}<button type="button" class="clear" aria-label={tr("Wis", "Clear")} onclick={() => (value = "")}><Ico name="circle-x" size={13} /></button>{/if}
</label>

<style>
  .search { display: flex; align-items: center; gap: var(--space-6); padding: 0 2px 0 var(--space-8); min-height: 30px; background: var(--field); border: 1px solid var(--line2); border-radius: var(--radius-control); color: var(--text3); }
  input { flex: 1; min-width: 0; padding: 0; border: none !important; background: none; box-shadow: none !important; }
  .clear { width: 24px; height: 24px; padding: 0; border: none; background: none; display: inline-flex; align-items: center; justify-content: center; color: var(--text3); }
  :global(.phone) .search { min-height: 38px; border: none; border-radius: 8px; }
  :global(.phone) .clear { width: 28px; height: 28px; }
</style>
