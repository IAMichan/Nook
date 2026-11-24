<script lang="ts">
  // The one tab bar over a Settings page that holds several subjects (`SettingsPartTabs`): a segmented row of the
  // page's subjects, each with its line icon, the open one raised (`NookTabBar` with `segmented`); ← and → move between
  // them as in any tab list.
  import Ico from "../../components/ui/Ico.svelte";
  import { sectionTitle, type SettingsSectionId } from "../../lib/settings-pages";
  import { tr } from "../../lib/i18n.svelte";
  let { parts, selected, onselect, icon }: { parts: SettingsSectionId[]; selected: SettingsSectionId; onselect: (part: SettingsSectionId) => void; icon?: (part: SettingsSectionId) => string } = $props();

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
      onclick={() => part !== selected && onselect(part)}>{#if icon}<Ico name={icon(part)} size={13} />{/if}{sectionTitle(part)}</button>
  {/each}
</div>

<style>
  /* The Mac's segmented NookTabBar: a graphite track with a line around it, 2 px in; each tab 12 pt medium with an
     11 pt icon, 10 by 4 pt of room; the open one on a chip-round fill of paper at 14 %. */
  .part-tabs { display: inline-flex; align-self: flex-start; gap: var(--space-2); max-width: 100%; overflow-x: auto; scrollbar-width: none; background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-control); padding: var(--space-2); margin-top: var(--space-6); }
  .part-tabs::-webkit-scrollbar { display: none; }
  button { flex: none; display: inline-flex; align-items: center; gap: 5px; border: none; background: none; color: var(--text2); padding: var(--space-4) 10px; border-radius: var(--radius-chip); font: var(--text-detail); font-weight: 500; line-height: 1.2; white-space: nowrap; }
  button:hover:not(:disabled) { background: color-mix(in srgb, var(--paper) 6%, transparent); color: var(--text2); }
  button.on, button.on:hover:not(:disabled) { background: color-mix(in srgb, var(--paper) 14%, transparent); color: var(--paper); }
</style>
