<script lang="ts">
  // The one tab bar over a Settings page that holds several subjects (`SettingsPartTabs`): a segmented row of the
  // page's subjects, the open one raised; ← and → move between them as in any tab list.
  import { sectionTitle, type SettingsSectionId } from "../../lib/settings-pages";
  import { tr } from "../../lib/i18n.svelte";
  let { parts, selected, onselect }: { parts: SettingsSectionId[]; selected: SettingsSectionId; onselect: (part: SettingsSectionId) => void } = $props();

  function keys(e: KeyboardEvent) {
    if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
    e.preventDefault();
    const i = parts.indexOf(selected);
    const next = parts[(i + (e.key === "ArrowRight" ? 1 : parts.length - 1)) % parts.length];
    onselect(next);
    (e.currentTarget as HTMLElement).querySelector<HTMLElement>(`[data-part="${next}"]`)?.focus();
  }
</script>

<div class="part-tabs" role="tablist" tabindex="-1" aria-label={tr("Onderdelen van deze pagina", "Parts of this page")} onkeydown={keys}>
  {#each parts as part (part)}
    <button role="tab" data-part={part} class:on={part === selected} aria-selected={part === selected} tabindex={part === selected ? 0 : -1}
      onclick={() => part !== selected && onselect(part)}>{sectionTitle(part)}</button>
  {/each}
</div>

<style>
  .part-tabs { display: inline-flex; gap: var(--space-2); max-width: 100%; overflow-x: auto; scrollbar-width: none; background: var(--field); border: 1px solid var(--line); border-radius: var(--radius-panel); padding: var(--space-2); margin: 0 0 var(--space-16); }
  .part-tabs::-webkit-scrollbar { display: none; }
  button { flex: none; border: none; background: none; color: var(--text2); padding: var(--space-4) var(--space-12); border-radius: var(--radius-control); font: var(--text-control); white-space: nowrap; }
  button:hover:not(:disabled) { background: none; color: var(--paper); }
  button.on, button.on:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
</style>
