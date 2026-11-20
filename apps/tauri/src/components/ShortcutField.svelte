<script lang="ts">
  // A global shortcut you set by pressing it: click, press the keys, done. Escape cancels, Backspace turns it off.
  // No more typing "Alt+CommandOrControl+Space" by hand.
  import { readableShortcut, recordShortcut } from "../lib/accelerator";
  import { tr } from "../lib/i18n.svelte";

  let { value, taken = false, onchange }: { value: string; taken?: boolean; onchange: (accelerator: string) => void } = $props();
  let recording = $state(false);
  let hint = $state<string | null>(null);

  function keydown(e: KeyboardEvent) {
    if (!recording) return;
    e.preventDefault();
    e.stopPropagation();
    const result = recordShortcut(e);
    switch (result.kind) {
      case "waiting": return;
      case "cancel": return stop();
      case "clear": onchange(""); return stop();
      case "invalid": hint = result.reason; return;
      case "done": onchange(result.accelerator); return stop();
    }
  }

  function stop() {
    recording = false;
    hint = null;
  }
</script>

<span class="field">
  <button
    type="button"
    class="shortcut"
    class:recording
    class:taken
    onclick={() => { recording = !recording; hint = null; }}
    onkeydown={keydown}
    onblur={stop}
    aria-label={recording ? tr("Druk nu de nieuwe toetsen in", "Press the new keys now") : tr("Sneltoets {keys}, klik om te wijzigen", "Shortcut {keys}, click to change", { keys: readableShortcut(value) })}
  >{#if recording}{tr("Druk op de toetsen…", "Press the keys…")}{:else if value.trim()}<span class="cap">{readableShortcut(value)}</span>{:else}{tr("Uit", "Off")}{/if}</button>
  {#if recording}<small class="faint">{hint ?? tr("Esc annuleert · Backspace zet uit", "Esc cancels · Backspace turns it off")}</small>
  {:else if taken}<small class="taken-note">{tr("Bezet door een andere app — kies een andere", "Taken by another app — choose another")}</small>{/if}
</span>

<style>
  /* The key on the right of its row as the Mac's `ShortcutRecorder` shows it: a borderless button holding a keycap
     (`Keycap`: 12 px medium on smoke with a line, chip-round, 22 px high); "Press the keys…" while recording. */
  .field { display: flex; flex-direction: column; align-items: flex-end; gap: var(--space-2); }
  .shortcut { height: auto; min-height: 22px; padding: 0; border: none; background: none; color: var(--text2); font: var(--text-body); }
  .shortcut:hover:not(:disabled) { background: none; color: var(--paper); }
  .cap { display: inline-grid; place-items: center; min-width: 24px; height: 22px; padding: 0 9px; border: 1px solid var(--line2); border-radius: var(--radius-chip); background: var(--smoke); color: var(--text-strong); font: var(--text-detail); font-weight: 500; box-shadow: 0 1px 0 color-mix(in srgb, var(--canvas) 12%, transparent); }
  .shortcut.taken .cap { border-color: color-mix(in srgb, var(--amber) 60%, var(--line2)); }
  small { font: var(--text-caption); font-weight: 400; color: var(--text2); }
  .taken-note { color: var(--amber); }
</style>
