<script lang="ts">
  // Settings › Shortcuts (`SettingsView+Shortcuts` and `ShortcutCheatSheetView` on the Mac): the global shortcuts you
  // set by pressing them, and a cheat sheet of the keys inside the main window, with a filter.
  import { api } from "../../lib/api";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { matchesSearch } from "../../lib/shell-routes";
  import { SHEET, keyLabel, type SheetEntry, type SheetGroup } from "../../lib/shortcut-sheet";
  import ShortcutField from "../../components/ShortcutField.svelte";

  const s = $derived(nook.settings!);
  const mac = typeof navigator !== "undefined" && /Mac/i.test(navigator.platform ?? "");

  // Shortcuts another app already holds: Rust says which after every change, the row shows it.
  let taken = $state<string[]>([]);
  $effect(() => {
    void s.shortcuts;
    if (!nook.info?.capabilities.globalShortcuts) return;
    // Registering happens on save; ask a moment later.
    const timer = setTimeout(() => api.shortcutProblems().then((p) => (taken = p)).catch(() => {}), 150);
    return () => clearTimeout(timer);
  });
  const shortcutNames = $derived<Record<string, string>>({
    chat: tr("Chatten", "Chat"), talk: tr("Praten", "Talk"), window: tr("Hoofdvenster", "Main window"), lookAlong: tr("Meekijken", "Look along"),
  });

  const groupNames = $derived<Record<SheetGroup, string>>({
    navigation: tr("Zoeken en navigeren", "Search and navigation"),
    session: tr("Gesprekken", "Conversations"),
    composer: tr("Schrijven", "Writing"),
    other: tr("Meer", "More"),
  });
  const names = $derived<Record<string, string>>({
    "Command palette": tr("Opdrachtenpalet", "Command palette"),
    "Search conversations, or settings in Settings": tr("Zoek in gesprekken, of in Instellingen naar een instelling", "Search conversations, or settings in Settings"),
    "Go to a page in the sidebar": tr("Naar een pagina in de zijbalk", "Go to a page in the sidebar"),
    "Open Settings": tr("Instellingen openen", "Open Settings"),
    "Search settings": tr("Zoek in de instellingen", "Search settings"),
    "New Nook": tr("Nieuwe Nook", "New Nook"),
    "Stop the answer": tr("Stop het antwoord", "Stop the answer"),
    "Show or hide the conversations": tr("Gesprekken tonen of verbergen", "Show or hide the conversations"),
    "Send": tr("Versturen", "Send"),
    "New line": tr("Nieuwe regel", "New line"),
    "Earlier questions": tr("Eerdere vragen", "Earlier questions"),
    "Stop the answer while it is being written": tr("Stop het antwoord terwijl het geschreven wordt", "Stop the answer while it is being written"),
    "Run the plan that waits for you": tr("Voer het plan uit dat op je wacht", "Run the plan that waits for you"),
    "Close a dialog or the palette": tr("Sluit een venster of het palet", "Close a dialog or the palette"),
  });
  const nameOf = (e: SheetEntry) => names[e.name] ?? e.name;

  let filter = $state("");
  const shown = $derived(SHEET.filter((e) => matchesSearch(filter, nameOf(e), groupNames[e.group], e.keys.map((k) => keyLabel(k, mac)).join(" "))));
  const groups = $derived((Object.keys(groupNames) as SheetGroup[]).filter((g) => shown.some((e) => e.group === g)));
</script>

<h2>{tr("Sneltoetsen", "Shortcuts")}</h2>
{#if nook.info?.capabilities.globalShortcuts}
  <h3>{tr("Overal", "Everywhere")}</h3>
  <div class="group">
    {#each Object.entries(s.shortcuts) as [action, accel] (action)}
      <div class="row">
        <span>{shortcutNames[action] ?? action}</span>
        <ShortcutField value={accel} taken={taken.includes(action)} onchange={(next) => nook.saveSettings({ shortcuts: { ...s.shortcuts, [action]: next } })} />
      </div>
    {/each}
    <p class="faint note">{tr("Klik op een sneltoets en druk de nieuwe toetsen in. Is hij al bezet door een andere app, dan zie je dat hier meteen.", "Click a shortcut and press the new keys. If another app already uses it, you see that here right away.")}</p>
  </div>
{/if}
<h3>{tr("In Nook", "In Nook")}</h3>
<input class="filter" bind:value={filter} placeholder={tr("Filter sneltoetsen", "Filter shortcuts")} aria-label={tr("Filter sneltoetsen", "Filter shortcuts")} />
{#if groups.length === 0}
  <p class="faint note">{tr("Geen sneltoets gevonden.", "No shortcut matches.")}</p>
{/if}
{#each groups as g (g)}
  <div class="group">
    <div class="caption">{groupNames[g]}</div>
    {#each shown.filter((e) => e.group === g) as e, i (g + i)}
      <div class="row">
        <span>{nameOf(e)}</span>
        <span class="keys">{#each e.keys as k, j (j)}<kbd>{keyLabel(k, mac)}</kbd>{/each}</span>
      </div>
    {/each}
  </div>
{/each}

<style>
  .filter { width: 100%; max-width: 360px; }
  .caption { font: var(--text-label); color: var(--text3); padding-top: var(--space-12); }
  .row { padding: var(--space-12) 0; }
  .keys { display: inline-flex; gap: var(--space-4); }
  kbd { font: var(--text-label); color: var(--text-strong); background: var(--smoke); border: 1px solid var(--line2); border-bottom-width: 2px; border-radius: var(--radius-chip); padding: 1px 7px; min-width: 22px; text-align: center; }
</style>
