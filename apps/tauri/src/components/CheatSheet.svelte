<script lang="ts">
  // The shortcut cheat sheet over the window (the Mac's `ShortcutCheatSheetView`, `?` or Ctrl+/): every key in groups,
  // with a filter. "Change keys" opens Settings › Shortcuts. Escape, the same key again or a click beside it closes it.
  import { tr } from "../lib/i18n.svelte";
  import { matchesSearch } from "../lib/shell-routes";
  import { SHEET, keyLabel } from "../lib/shortcut-sheet";
  import { sheetEntryName } from "../lib/shortcut-names";
  import { COMMAND_GROUPS, commandGroup, commandGroupName, commandName, type CommandGroup } from "../lib/command-names";
  import { DEFAULT_RULES, chordLabel, chordsFor } from "../lib/keybindings";
  import { keys } from "../lib/keybindings.svelte";
  import SearchField from "./ui/SearchField.svelte";
  import SectionLabel from "./ui/SectionLabel.svelte";
  import IconButton from "./ui/IconButton.svelte";
  import Ico from "./ui/Ico.svelte";

  let { onclose, onsettings }: { onclose: () => void; onsettings: () => void } = $props();
  const mac = typeof navigator !== "undefined" && /Mac/i.test(navigator.platform ?? "");
  // Every command with the keys it answers to now (your keybindings.json included), as the Mac's sheet reads the live
  // rules; the numbered jumps are one row. The composer field's own keys (Enter, Shift+Enter, ↑ ↓) come from the sheet.
  interface Row { id: string; name: string; group: CommandGroup; keys: string }
  const commands = [...new Set(DEFAULT_RULES.map((r) => r.command).concat(keys.user.map((r) => r.command)))].filter((c) => !c.startsWith("-"));
  const rows = $derived.by((): Row[] => {
    const out: Row[] = [];
    for (const id of commands) {
      if (/^tab\.jump[2-9]$/.test(id)) continue;
      const chords = chordsFor(id, keys.rules);
      if (!chords.length) continue;
      const label = id === "tab.jump1" ? `${chordLabel(chords[0], mac).replace(/1$/, "")}1…9` : chords.map((c) => chordLabel(c, mac)).join("  ");
      out.push({ id, name: commandName(id), group: commandGroup(id), keys: label });
    }
    for (const e of SHEET.filter((e) => e.group === "composer" && !e.keys.includes("Mod"))) {
      out.push({ id: e.name, name: sheetEntryName(e), group: "composer", keys: e.keys.map((k) => keyLabel(k, mac)).join("  ") });
    }
    return out;
  });

  let filter = $state("");
  const shown = $derived(rows.filter((r) => matchesSearch(filter, r.name, r.id, commandGroupName(r.group), r.keys)));

  let box = $state<HTMLDivElement>();
  $effect(() => {
    box?.querySelector("input")?.focus();
    const esc = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onclose(); }
    };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="scrim" onclick={onclose}>
  <div class="sheet" bind:this={box} role="dialog" aria-modal="true" aria-label={tr("Sneltoetsen", "Keyboard shortcuts")} tabindex="-1" onclick={(e) => e.stopPropagation()}>
    <div class="head">
      <h2>{tr("Sneltoetsen", "Keyboard shortcuts")}</h2>
      <button class="change" onclick={onsettings}>{tr("Toetsen aanpassen", "Change keys")}</button>
      <IconButton title={tr("Sluit", "Close")} size={24} onclick={onclose}><Ico name="x" size={13} /></IconButton>
    </div>
    <div class="filter"><SearchField bind:value={filter} placeholder={tr("Filter sneltoetsen", "Filter shortcuts")} /></div>
    <div class="rule"></div>
    <div class="rows">
      {#each COMMAND_GROUPS as group (group)}
        {@const inGroup = shown.filter((e) => e.group === group)}
        {#if inGroup.length}
          <section>
            <SectionLabel text={commandGroupName(group)} />
            {#each inGroup as row (row.id)}
              <div class="row">
                <span class="name">{row.name}</span>
                <span class="keys">{row.keys}</span>
              </div>
            {/each}
          </section>
        {/if}
      {/each}
      {#if !shown.length}<p class="none">{tr("Geen sneltoets gevonden.", "No shortcut matches.")}</p>{/if}
    </div>
  </div>
</div>

<style>
  .scrim { position: fixed; inset: 0; z-index: 60; display: flex; justify-content: center; align-items: flex-start; padding: var(--space-48) var(--space-16) 0; }
  .sheet {
    width: 100%; max-width: 560px; display: flex; flex-direction: column; background: var(--graphite);
    border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); outline: none;
    animation: reveal var(--motion-reveal, 180ms) var(--ease-settle, ease-out);
  }
  .head { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-16); }
  h2 { flex: 1; margin: 0; font: var(--text-title); color: var(--paper); }
  .change { padding: 0; border: 0; background: none; font: var(--text-label); color: var(--iris); }
  .change:hover { text-decoration: underline; }
  .filter { padding: 0 var(--space-16); }
  .rule { height: 1px; margin-top: var(--space-12); background: var(--hairline); }
  .rows { max-height: 440px; overflow-y: auto; padding: var(--space-8) var(--space-16) var(--space-16); display: flex; flex-direction: column; gap: var(--space-12); }
  section { display: flex; flex-direction: column; gap: var(--space-6); }
  section :global(.section-label) { padding-left: 0; }
  .row { display: flex; align-items: baseline; gap: var(--space-12); }
  .name { flex: 1; min-width: 0; font: var(--text-body); color: var(--paper); }
  .keys { font: var(--text-code); color: var(--text2); white-space: pre; }
  .none { margin: 0; font: var(--text-detail); color: var(--text3); }
  @keyframes reveal { from { opacity: 0; transform: translateY(-4px); } }
  @media (prefers-reduced-motion: reduce) { .sheet { animation: none; } }
</style>
