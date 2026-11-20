<script lang="ts">
  // Settings › Shortcuts (`SettingsView+Shortcuts` on the Mac): the shortcuts that work anywhere, set by pressing them,
  // and the keys inside Nook's window, searchable, as the Mac's "Panel keys".
  import { api } from "../../lib/api";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { matchesSearch } from "../../lib/shell-routes";
  import { DEFAULT_RULES, chordLabel, chordText, chordsFor, conflicts, eventChord, rebind } from "../../lib/keybindings";
  import { keys } from "../../lib/keybindings.svelte";
  import { commandName } from "../../lib/command-names";
  import ShortcutField from "../../components/ShortcutField.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { services, type ServicePrefs } from "../../lib/services";

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
  // The Mac's names (`ShortcutRecorder.title`), in its order: talk, ask, look along; the main window is Windows' own.
  const shortcutNames = $derived<Record<string, string>>({
    talk: tr("Praat met Nook", "Talk to Nook"), chat: tr("Vraag iets (typen)", "Ask something (typing)"),
    lookAlong: tr("Laat Nook meekijken", "Let Nook look along"), window: tr("Hoofdvenster", "Main window"),
  });
  const order = ["talk", "chat", "lookAlong", "window"];
  const actions = $derived(Object.keys(s.shortcuts).sort((a, b) => (order.indexOf(a) + 1 || 99) - (order.indexOf(b) + 1 || 99)));
  // The Mac's three come first, then its screen part and call rows; Windows' own (the main window) close the list.
  const macActions = $derived(actions.filter((a) => order.slice(0, 3).includes(a)));
  const ownActions = $derived(actions.filter((a) => !order.slice(0, 3).includes(a)));


  // The screen area shortcut (the Mac's "Ask about a part of the screen") lives with the service prefs.
  let prefs = $state<ServicePrefs | null>(null);
  $effect(() => {
    services.prefs().then((p) => (prefs = p)).catch(() => {});
  });
  async function savePrefs(patch: Partial<ServicePrefs>) {
    if (prefs) prefs = await services.savePrefs({ ...prefs, ...patch });
  }

  // Panel keys from the live rules: every command, the keys it answers to, and whether you changed it.
  $effect(() => keys.start());
  // In the Mac's order (`Keybindings.commandIDs`), one flat list; commands the Mac lacks follow in rule order.
  const MAC_ORDER = ["composer.send", "composer.sendAlternate", "composer.newline", "composer.stash", "composer.dictate", "composer.historyPrevious",
    "composer.historyNext", "composer.access", "composer.undo", "composer.redo", "queue.steerFirst", "chat.find", "search.toggle", "commandPalette.toggle",
    "shortcuts.cheatSheet", "session.new", "session.previous", "session.next", "diff.toggle", "modelPicker.toggle", "session.settle", "session.pin",
    "session.undo", "session.interrupt", "panel.reopenClosed", "selection.quote", "selection.ask", "session.back", "session.forward", "session.rename",
    "session.openInEditor", "session.copyReference", "composer.startInBackground", "sidebar.toggle", "terminal.toggle", "sidePanel.toggle",
    "sessionPanel.toggle", "tab.close", "terminal.splitRight", "terminal.splitDown", "focus.next", "focus.previous", "effortPicker.toggle",
    "permissionPicker.toggle", "effort.increase", "effort.decrease", "composer.pasteAsText"];
  const macRank = (c: string) => (MAC_ORDER.indexOf(c) + 1) || MAC_ORDER.length + 1;
  const ruleCommands = [...new Set(DEFAULT_RULES.map((r) => r.command))].filter((c) => !/^tab\.jump[2-9]$/.test(c))
    .map((c, i) => ({ c, i })).sort((a, b) => macRank(a.c) - macRank(b.c) || a.i - b.i).map((x) => x.c);
  let recording = $state<string | null>(null);
  const keyRows = $derived.by(() => {
    const clashes = conflicts(keys.rules);
    return ruleCommands.map((id) => {
      const chords = chordsFor(id, keys.rules).map((c) => chordLabel(c, mac));
      const clash = clashes.find((x) => x.commands.includes(id))?.commands.filter((c) => c !== id).map(commandName).join(", ");
      return {
        id, name: commandName(id), clash,
        chords: id === "tab.jump1" ? chords.map((c) => c.replace(/1$/, "1…9")) : chords,
        custom: keys.user.some((r) => r.command === id || r.command === `-${id}`),
        // The numbered jumps keep their numbers.
        fixed: id === "tab.jump1",
      };
    }).filter((r) => matchesSearch(filter, r.name, r.id, r.chords.join(" ")));
  });
  $effect(() => {
    if (!recording) return;
    const command = recording;
    const take = (e: KeyboardEvent) => {
      if (["Control", "Shift", "Alt", "Meta"].includes(e.key)) return;
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Escape") { recording = null; return; }
      const chord = eventChord(e);
      recording = null;
      if (chord) keys.save(rebind(keys.user, command, chordText(chord))).catch(() => {});
    };
    window.addEventListener("keydown", take, true);
    return () => window.removeEventListener("keydown", take, true);
  });

  let filter = $state("");
</script>

{#if nook.info?.capabilities.globalShortcuts}
  <h3>{tr("Overal op je computer", "Anywhere on your computer")}</h3>
  <div class="group">
    {#snippet shortcutRow(action: string)}
      <div class="row">
        <span>{shortcutNames[action] ?? action}</span>
        <ShortcutField value={s.shortcuts[action]} taken={taken.includes(action)} onchange={(next) => nook.saveSettings({ shortcuts: { ...s.shortcuts, [action]: next } })} />
      </div>
    {/snippet}
    {#each macActions as action (action)}{@render shortcutRow(action)}{/each}
    {#if prefs && nook.info?.capabilities.screenPart}
      <div class="row">
        <span>{tr("Vraag over een deel van het scherm", "Ask about a part of the screen")}</span>
        <span class="inline"><button class="small" title={tr("Trek een kader om een stuk van je scherm; dat gaat als afbeelding naar de chat.", "Draw a frame around part of your screen; it goes to the chat as an image.")} onclick={() => services.partBegin()}>{tr("Kader trekken", "Draw a frame")}</button><ShortcutField value={prefs.screenPartShortcut} onchange={(next) => savePrefs({ screenPartShortcut: next })} /></span>
      </div>
    {/if}
    {#if prefs && nook.info?.capabilities.microphone}
      <div class="row">
        <span>{tr("Gesprek opnemen", "Record a call")}</span>
        <ShortcutField value={prefs.notesShortcut} onchange={(next) => savePrefs({ notesShortcut: next })} />
      </div>
    {/if}
    {#each ownActions as action (action)}{@render shortcutRow(action)}{/each}
    <p class="note">{tr("Klik op een sneltoets en druk de nieuwe toetsen in. Is hij al bezet door een andere app, dan zie je dat hier meteen.", "Click a shortcut and press the new keys. If another app already uses it, you see that here right away.")}</p>
  </div>
{/if}
<!-- The Mac's "Panel keys" (`KeybindingsSettingsSection`): a search inside the card, then every command with the keys
     it answers to now. Record takes the next chord you press (Escape cancels); Reset puts the default back. Both are
     written to keybindings.json in Nook's data folder, which you may also edit by hand. -->
<h3>{tr("Paneeltoetsen", "Panel keys")}</h3>
<p class="section-info">{tr("Zo werken de toetsen in het paneel nu: de standaard, plus je eigen regels uit keybindings.json.", "How the keys in the panel work now: the defaults, plus your own rules from keybindings.json.")}</p>
<div class="group">
  <label class="row key-search">
    <Ico name="search" size={13} />
    <input bind:value={filter} placeholder={tr("Zoek een toets of commando", "Search a key or command")} aria-label={tr("Zoek een toets of commando", "Search a key or command")} />
  </label>
  {#if keys.skipped > 0}<p class="note">{tr("{n} regels in keybindings.json kon Nook niet gebruiken.", "Nook could not use {n} rules in keybindings.json.", { n: keys.skipped })}</p>{/if}
  {#if keyRows.length === 0}
    <p class="note">{tr("Geen toets of commando gevonden.", "No key or command found.")}</p>
  {/if}
  {#each keyRows as r (r.id)}
      <div class="row">
        <span>{r.name}{#if r.clash}<br /><small class="clash">{tr("Deze toets doet ook: {other}", "This key also does: {other}", { other: r.clash })}</small>{/if}</span>
        <span class="inline">
          {#if recording === r.id}
            <kbd class="recording">{tr("Druk de toetsen in…", "Press the keys…")}</kbd>
          {:else}
            {#each r.chords as c (c)}<kbd>{c}</kbd>{/each}
            {#if !r.chords.length}<span class="note">{tr("Geen toets", "No key")}</span>{/if}
          {/if}
          {#if !r.fixed}
            <button class="small" onclick={() => (recording = recording === r.id ? null : r.id)}>{recording === r.id ? tr("Annuleren", "Cancel") : tr("Opnemen", "Record")}</button>
            {#if r.custom}<button class="ghost small" onclick={() => keys.save(rebind(keys.user, r.id, null))}>{tr("Herstel", "Reset")}</button>{/if}
          {/if}
        </span>
      </div>
    {/each}
</div>

<style>
  .key-search { flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-6); color: var(--text3); }
  .key-search input { flex: 1; min-width: 0; padding: 0; border: none; background: none; box-shadow: none; outline: none; color: var(--paper); font: var(--text-body); }
  /* `Keycap`: 12 px medium on smoke with a line, chip-round, 22 px high. */
  .inline { display: inline-flex; align-items: center; gap: var(--space-6); flex-wrap: wrap; justify-content: flex-end; }
  .small { padding: var(--space-2) var(--space-8); font: var(--text-detail); }
  .recording { color: var(--iris); border-color: var(--iris); }
  .clash { color: var(--amber); }
  kbd { display: inline-grid; place-items: center; min-width: 24px; height: 22px; padding: 0 9px; border: 1px solid var(--line2); border-radius: var(--radius-chip); background: var(--smoke); color: var(--text-strong); font: var(--text-detail); font-weight: 500; }
</style>
