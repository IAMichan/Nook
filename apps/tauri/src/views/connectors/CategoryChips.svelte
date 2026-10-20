<script lang="ts">
  // De categorieën onder het zoekveld van Accounts & koppelingen: Alles, en dan één per soort dienst.
  import { categories } from "../../lib/connectors";

  let { selected = $bindable(null) }: { selected: string | null } = $props();
</script>

<div class="chips" role="group" aria-label="Categorie">
  <button class:on={selected === null} aria-pressed={selected === null} onclick={() => (selected = null)}>Alles</button>
  {#each categories as cat (cat.id)}
    <button class:on={selected === cat.id} aria-pressed={selected === cat.id} onclick={() => (selected = cat.id)}>{cat.title}</button>
  {/each}
</div>

<style>
  .chips { display: flex; gap: 6px; overflow-x: auto; padding: 2px 0; margin-top: 8px; scrollbar-width: none; }
  button { flex: none; font-size: 11px; font-weight: 500; padding: 5px 10px; border-radius: 999px; border: none; background: color-mix(in srgb, var(--paper) 7%, transparent); }
  button.on { background: var(--iris); color: var(--on-iris); }
</style>
